use rust_ai_pc_memory_collector::mask::mask_paths;

#[test]
fn ユーザープロファイルは_チルダに置き換える() {
    assert_eq!(mask_paths(r"C:\Users\alice\AppData\Local\x"), r"~\AppData\Local\x");
}

#[test]
fn 大小文字は区別しない() {
    assert_eq!(mask_paths(r"c:\users\ALICE\a"), r"~\a");
}

#[test]
fn コマンドラインの中の複数のユーザープロファイルも置き換える() {
    assert_eq!(
        mask_paths(r#""C:\Users\alice\a.exe" --dir=C:\Users\bob --x"#),
        r#""~\a.exe" --dir=~ --x"#
    );
}

#[test]
fn スラッシュ区切りも置き換える() {
    assert_eq!(mask_paths("C:/Users/alice/a"), "~/a");
}

#[test]
fn linux_と_mac_のホームも置き換える() {
    assert_eq!(mask_paths("/home/alice/.cache/x"), "~/.cache/x");
    assert_eq!(mask_paths("/Users/alice/Library/y"), "~/Library/y");
}

#[test]
fn git_bash_形式と_wsl_形式のユーザープロファイルも置き換える() {
    assert_eq!(mask_paths("source /c/Users/alice/.claude/x"), "source ~/.claude/x");
    assert_eq!(mask_paths("/mnt/c/Users/alice/x"), "~/x");
    assert_eq!(mask_paths("/D/users/Bob/y"), "~/y");
}

#[test]
fn ユーザープロファイルでないパスは変えない() {
    assert_eq!(mask_paths(r"C:\Windows\System32\cmd.exe"), r"C:\Windows\System32\cmd.exe");
    assert_eq!(mask_paths(r"C:\work\2026\x"), r"C:\work\2026\x");
}

#[test]
fn ユーザー名が空のときは変えない() {
    assert_eq!(mask_paths(r"C:\Users\ "), r"C:\Users\ ");
    assert_eq!(mask_paths(r"C:\Users\"), r"C:\Users\");
}

#[test]
fn 日本語のユーザー名も置き換える() {
    assert_eq!(mask_paths(r"C:\Users\山田\a"), r"~\a");
}
