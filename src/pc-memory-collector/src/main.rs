use rust_ai_pc_memory_collector::collect::SysinfoSource;
use rust_ai_pc_memory_collector::config::{parse_args, USAGE};
use rust_ai_pc_memory_collector::db::open_and_migrate;
use rust_ai_pc_memory_collector::request::{watch_inbox, RESTART_EXIT_CODE};
use rust_ai_pc_memory_collector::runner::Collector;
use rust_ai_pc_memory_collector::timeutil::{format_jst, now_ms};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::time::Duration;

// 標準出力・標準エラーは、サービス（winsw）がログに回す。日時は JST・ミリ秒 3 桁
fn log(message: &str) {
    println!("{} {message}", format_jst(now_ms()));
}

fn log_err(message: &str) {
    eprintln!("{} {message}", format_jst(now_ms()));
}

// 受信箱を走査し、再起動を求められたら、停止を記録して、終了コード 75 で終わる。
// 0 以外なので、サービス（winsw）の「異常終了なら起動し直す」が、新しい exe で起動し直す。
// 手で動かしているときは、終了するだけ（誰も起動し直さない）
fn request_restart_if_asked(collector: &mut Collector<SysinfoSource>) {
    if collector.handle_requests(now_ms()) {
        collector.record_stop(now_ms());
        log("再起動の依頼を受け付けたため、終了します（終了コード 75。サービスなら、winsw が起動し直します）");
        std::process::exit(RESTART_EXIT_CODE);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--help" || a == "-h") {
        println!("{USAGE}");
        return;
    }
    let cfg = match parse_args(&args) {
        Ok(c) => c,
        Err(e) => {
            log_err(&format!("引数のエラー: {e}"));
            std::process::exit(2);
        }
    };

    log(&format!("開始します（v{}）。DB: {}", env!("CARGO_PKG_VERSION"), cfg.db_path.display()));
    // 開けない・版を当てられないときは、非 0 で終わり、サービスの再起動に任せる
    let conn = match open_and_migrate(&cfg.db_path, &cfg.backup_dir, now_ms()) {
        Ok(c) => c,
        Err(e) => {
            log_err(&format!("DB を使えません: {e}"));
            std::process::exit(1);
        }
    };

    let times = cfg.times;
    let mut done_times: u32 = 0;
    let inbox = cfg.request_dir.join("inbox");
    let mut collector = Collector::new(conn, cfg, SysinfoSource::new());
    collector.record_start(now_ms());
    // 依頼の受信箱。前のプロセスが受け取った再起動の依頼が残っていれば、ここで完了にして、新しい版を書く
    collector.ensure_request_dirs(now_ms());
    for m in collector.recover_requests(now_ms()) {
        log(&m);
    }

    let stop = Arc::new(AtomicBool::new(false));
    // 後始末（停止イベントの記録）が済んだことを、ハンドラへ知らせる
    let (done_tx, done_rx) = mpsc::channel::<()>();
    {
        let stop = Arc::clone(&stop);
        // 停止（Ctrl+C 相当・終了要求）を受けたら、メインが畳んで終わる。
        // Windows の「閉じる」系の通知は、ハンドラが戻るとすぐプロセスが終わる。後始末が済むまでここで待つ（最大 4 秒）
        let handler = move || {
            stop.store(true, Ordering::SeqCst);
            let _ = done_rx.recv_timeout(Duration::from_secs(4));
        };
        if let Err(e) = ctrlc::set_handler(handler) {
            log_err(&format!("停止の受け付けを設定できません: {e}"));
        }
    }

    // 起動した時刻から数えず、時計の区切り（毎分 hh:mm:00・毎時 hh:00:00 等）で動く。最初の実行も、次の区切りまで待つ
    collector.align_to_boundaries(now_ms());
    log(&format!("最初の実行は {} です", format_jst(collector.next_wake(now_ms()))));

    // 依頼の受信箱を、OS のファイル監視で見る。通知は、待ちを起こすきっかけ。受け取りは、必ず走査で行う。
    // 監視を始められないときは、0.5 秒ごとに走査する
    let watch = match watch_inbox(&inbox) {
        Ok(w) => Some(w),
        Err(e) => {
            log_err(&format!("{e}（代わりに、0.5 秒ごとに受信箱を走査します）"));
            None
        }
    };

    // 起動中に、止まっている間に置かれた依頼があれば、ここで受け取る
    request_restart_if_asked(&mut collector);

    loop {
        // 次の区切りまで待つ。停止の要求と、受信箱の通知を見逃さないため、短く区切って待つ
        let wake = collector.next_wake(now_ms());
        while !stop.load(Ordering::SeqCst) {
            let remaining = wake - now_ms();
            if remaining <= 0 {
                break;
            }
            let slice = Duration::from_millis(remaining.min(500) as u64);
            match &watch {
                Some((_watcher, rx)) => {
                    if rx.recv_timeout(slice).is_ok() {
                        while rx.try_recv().is_ok() {} // 続けて来た通知は、まとめて 1 回の走査にする
                        request_restart_if_asked(&mut collector);
                    }
                }
                None => {
                    std::thread::sleep(slice);
                    request_restart_if_asked(&mut collector);
                }
            }
        }
        if stop.load(Ordering::SeqCst) {
            break;
        }

        let now = now_ms();
        let report = collector.tick(now);
        // 区切りごとの走査（通知の取りこぼしへの安全網）
        request_restart_if_asked(&mut collector);
        if report.snapshot {
            log("プロセスのスナップショットを書きました");
        }
        match &report.backup {
            Some(Ok(path)) => log(&format!("バックアップを作りました: {}", path.display())),
            Some(Err(e)) => log_err(&format!("バックアップに失敗: {e}")),
            None => {}
        }
        for e in &report.errors {
            log_err(e);
        }
        if report.fatal {
            log_err("書き込みの失敗が続いたため、終了します（サービスの再起動に任せます）");
            std::process::exit(1);
        }
        done_times += 1;
        if times.is_some_and(|t| done_times >= t) {
            break;
        }
    }

    collector.record_stop(now_ms());
    log("停止しました");
    let _ = done_tx.send(());
}
