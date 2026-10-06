//! 収集。OS ごとの取り方の違いは `Source` の実装に閉じ込め、DB・周期・バックアップは共通にする。

use sysinfo::{ProcessRefreshKind, ProcessesToUpdate, System, UpdateKind};

/// 1 分ごとのシステム全体のメモリ（byte）。OS に無い値は None
#[derive(Debug, Clone, PartialEq)]
pub struct SystemMemory {
    pub phys_total: u64,
    pub phys_avail: u64,
    pub swap_total: Option<u64>,
    pub swap_used: Option<u64>,
    pub commit_limit: Option<u64>,
    pub commit_used: Option<u64>,
}

/// 1 時間ごとのプロセス 1 件
#[derive(Debug, Clone)]
pub struct ProcessInfo {
    pub pid: u32,
    pub parent_pid: Option<u32>,
    /// 起動時刻（UTC のエポック・ミリ秒）。pid の再利用と区別するため、必ず組み合わせて使う
    pub start_time_ms: i64,
    pub name: String,
    pub exe_path: Option<String>,
    /// 取れなかったときは None
    pub command_line: Option<String>,
    /// 読めなかった（権限が無い）ときは None。0 で書くと「暇だった」と読めてしまう
    pub cpu_total_ms: Option<u64>,
    /// 読めなかったときは None（`is_unreadable`）
    pub memory_bytes: Option<u64>,
    pub virtual_bytes: Option<u64>,
}

/// 権限が無くてプロセスの情報を読めなかったか。sysinfo は読めないとき、エラーではなく 0 を返す。
/// 実測（非管理者）で、メモリが 0 のものは、実行ファイルのパスも取れていない点で完全に一致した
pub fn is_unreadable(memory_bytes: u64, has_exe: bool) -> bool {
    memory_bytes == 0 && !has_exe
}

pub trait Source {
    /// 管理者権限（昇格済み、または LocalSystem）で動いているか。権限で、読めるプロセスの数が大きく変わる
    fn is_admin(&mut self) -> bool;
    fn system_memory(&mut self) -> SystemMemory;
    /// (論理 CPU 数, プロセス一覧)
    fn processes(&mut self) -> (u32, Vec<ProcessInfo>);
}

/// sysinfo による実装（Windows・Linux・Mac 共通）
pub struct SysinfoSource {
    sys: System,
}

impl SysinfoSource {
    pub fn new() -> Self {
        SysinfoSource { sys: System::new() }
    }
}

impl Default for SysinfoSource {
    fn default() -> Self {
        Self::new()
    }
}

// 空白を含む引数は引用符で囲み、読み取りやすくする（sysinfo は引数を分割して返す）
fn join_args(args: &[std::ffi::OsString]) -> String {
    args.iter()
        .map(|a| {
            let s = a.to_string_lossy();
            if s.contains(' ') && !s.starts_with('"') {
                format!("\"{s}\"")
            } else {
                s.into_owned()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

impl Source for SysinfoSource {
    fn is_admin(&mut self) -> bool {
        platform::is_admin()
    }

    fn system_memory(&mut self) -> SystemMemory {
        self.sys.refresh_memory();
        let (commit_limit, commit_used) = platform::commit();
        SystemMemory {
            phys_total: self.sys.total_memory(),
            phys_avail: self.sys.available_memory(),
            // Windows ではページファイル。0 は「無い」ではなく、取れなかった値として NULL にする
            swap_total: Some(self.sys.total_swap()).filter(|n| *n > 0),
            swap_used: Some(self.sys.used_swap()).filter(|_| self.sys.total_swap() > 0),
            commit_limit,
            commit_used,
        }
    }

    fn processes(&mut self) -> (u32, Vec<ProcessInfo>) {
        let kind = ProcessRefreshKind::nothing().with_cpu().with_memory().with_cmd(UpdateKind::Always).with_exe(UpdateKind::Always);
        self.sys.refresh_processes_specifics(ProcessesToUpdate::All, true, kind);
        let list = self
            .sys
            .processes()
            .values()
            .map(|p| {
                let readable = !is_unreadable(p.memory(), p.exe().is_some());
                ProcessInfo {
                    pid: p.pid().as_u32(),
                    parent_pid: p.parent().map(|pp| pp.as_u32()),
                    start_time_ms: p.start_time() as i64 * 1_000,
                    name: p.name().to_string_lossy().into_owned(),
                    exe_path: p.exe().map(|e| e.to_string_lossy().into_owned()),
                    command_line: Some(join_args(p.cmd())).filter(|s| !s.is_empty()),
                    cpu_total_ms: Some(p.accumulated_cpu_time()).filter(|_| readable),
                    memory_bytes: Some(p.memory()).filter(|_| readable),
                    virtual_bytes: Some(p.virtual_memory()).filter(|_| readable),
                }
            })
            .collect();
        let cpus = std::thread::available_parallelism().map(|n| n.get() as u32).unwrap_or(1);
        (cpus, list)
    }
}

#[cfg(windows)]
mod platform {
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
    use windows_sys::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
    use windows_sys::Win32::System::ProcessStatus::{GetPerformanceInfo, PERFORMANCE_INFORMATION};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    // 自分のトークンが昇格済みか。UAC で昇格していない管理者アカウントは false、サービス（LocalSystem）は true
    pub fn is_admin() -> bool {
        // SAFETY: 自分のプロセスのトークンを開き、TOKEN_ELEVATION の大きさを渡して読む。開いたトークンは必ず閉じる
        unsafe {
            let mut token: HANDLE = std::ptr::null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return false;
            }
            let mut elevation = TOKEN_ELEVATION { TokenIsElevated: 0 };
            let mut returned = 0u32;
            let ok = GetTokenInformation(
                token,
                TokenElevation,
                &mut elevation as *mut TOKEN_ELEVATION as *mut core::ffi::c_void,
                std::mem::size_of::<TOKEN_ELEVATION>() as u32,
                &mut returned,
            );
            CloseHandle(token);
            ok != 0 && elevation.TokenIsElevated != 0
        }
    }

    // (コミットの上限, コミットの使用量)。byte
    pub fn commit() -> (Option<u64>, Option<u64>) {
        // SAFETY: 構造体を 0 で初期化し、cb に自分の大きさを入れて渡す（API の規約どおり）
        unsafe {
            let mut pi: PERFORMANCE_INFORMATION = std::mem::zeroed();
            pi.cb = std::mem::size_of::<PERFORMANCE_INFORMATION>() as u32;
            if GetPerformanceInfo(&mut pi, pi.cb) == 0 {
                return (None, None);
            }
            let page = pi.PageSize as u64;
            (Some(pi.CommitLimit as u64 * page), Some(pi.CommitTotal as u64 * page))
        }
    }
}

#[cfg(target_os = "linux")]
mod platform {
    // root かどうかの判定は、まだ実装しない（実機で確かめられないため、常に false。対応は別に行う）
    pub fn is_admin() -> bool {
        false
    }

    // /proc/meminfo の CommitLimit・Committed_AS（kB）
    pub fn commit() -> (Option<u64>, Option<u64>) {
        let Ok(text) = std::fs::read_to_string("/proc/meminfo") else { return (None, None) };
        let get = |key: &str| {
            text.lines()
                .find_map(|l| l.strip_prefix(key))
                .and_then(|rest| rest.trim().trim_end_matches("kB").trim().parse::<u64>().ok())
                .map(|kb| kb * 1024)
        };
        (get("CommitLimit:"), get("Committed_AS:"))
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
mod platform {
    pub fn is_admin() -> bool {
        false
    }

    // Mac などには、同じ意味の値が無い
    pub fn commit() -> (Option<u64>, Option<u64>) {
        (None, None)
    }
}
