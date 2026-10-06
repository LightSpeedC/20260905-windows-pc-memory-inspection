// 実際の exe を起動して、再起動の依頼から、終了コード 75 で終わるまで、そして、次の起動で依頼が完了になるまでを通す。
// 区切りの時刻（既定は毎分）を待たずに、監視の通知で受け取る（60 秒の間隔のまま、数秒で終わること）
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const EXE: &str = env!("CARGO_BIN_EXE_rust-ai-pc-memory-collector");

fn wait_for(path: &Path, secs: u64) -> bool {
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(secs) {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}

#[test]
fn 再起動の依頼で_終了コード_75_で終わり_次の起動で完了になる() {
    let base = tempfile::tempdir().unwrap();
    let inbox = base.path().join("_data").join("request").join("inbox");

    let mut child = Command::new(EXE)
        .args(["--base-dir", &base.path().to_string_lossy()])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert!(wait_for(&inbox, 10), "受信箱が作られない");
    // 監視が始まるのを少し待つ
    std::thread::sleep(Duration::from_millis(500));

    let tmp = inbox.join("req-20261006-233700.tmp");
    fs::write(&tmp, r#"{"action":"restart"}"#).unwrap();
    fs::rename(&tmp, inbox.join("req-20261006-233700.json")).unwrap();

    let start = Instant::now();
    let status = loop {
        if let Some(s) = child.try_wait().unwrap() {
            break s;
        }
        if start.elapsed() > Duration::from_secs(8) {
            child.kill().unwrap();
            panic!("8 秒待っても、終了しない（区切りの時刻を待っている可能性）");
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(status.code(), Some(75), "winsw が異常終了として起動し直せる終了コードでない");
    assert!(base.path().join("_data/request/proc/req-20261006-233700.json").exists(), "処理中に残っていない");

    // 次の起動（winsw が起動し直す相当）。残った依頼を完了にする
    let second = Command::new(EXE)
        .args(["--base-dir", &base.path().to_string_lossy(), "--memory-interval-sec", "1", "--times", "1"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .unwrap();
    assert!(second.success());
    let comp = base.path().join("_data/request/comp/req-20261006-233700.json");
    assert!(comp.exists(), "完了に移っていない");
    let text = fs::read_to_string(comp).unwrap();
    assert!(text.contains(env!("CARGO_PKG_VERSION")), "新しい版が書かれていない: {text}");
}
