//! ユーザープロファイルのパスを `~` に置き換える。
//!
//! サービスは LocalSystem で動くため、環境変数のプロファイルは使えない。
//! 他のユーザーのパスが対象なので、`X:\Users\<名前>`・`/home/<名前>`・`/Users/<名前>` の形で見つけて置き換える。

fn starts_with_ignore_case(bytes: &[u8], needle: &[u8]) -> bool {
    bytes.len() >= needle.len() && bytes[..needle.len()].eq_ignore_ascii_case(needle)
}

// 名前の終わり: 区切り・空白・引用符・文字列の終わり。日本語など ASCII 以外は名前の一部
fn name_end(bytes: &[u8], from: usize) -> usize {
    let mut i = from;
    while i < bytes.len() && !matches!(bytes[i], b'\\' | b'/' | b' ' | b'\t' | b'"' | b'\'') {
        i += 1;
    }
    i
}

// 単語の途中にある /home/ などを拾わないため、直前は区切り的な文字に限る
fn at_token_start(bytes: &[u8], i: usize) -> bool {
    i == 0 || matches!(bytes[i - 1], b' ' | b'\t' | b'"' | b'\'' | b'=' | b':' | b';' | b',' | b'(')
}

pub fn mask_paths(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut copied = 0; // text[..copied] は out に写し済み
    let mut i = 0;
    while i < bytes.len() {
        // (置き換え範囲の始まり, 名前の始まり)
        let found = if i >= 1
            && bytes[i - 1].is_ascii_alphabetic()
            && (starts_with_ignore_case(&bytes[i..], b":\\users\\") || starts_with_ignore_case(&bytes[i..], b":/users/"))
        {
            Some((i - 1, i + 8))
        } else if at_token_start(bytes, i) && starts_with_ignore_case(&bytes[i..], b"/home/") {
            Some((i, i + 6))
        } else if i >= 2
            && bytes[i - 1].is_ascii_alphabetic()
            && bytes[i - 2] == b'/'
            && starts_with_ignore_case(&bytes[i..], b"/users/")
        {
            // Git bash の /c/Users/<名前>、WSL の /mnt/c/Users/<名前>
            let start = if i >= 6 && bytes[i - 6..i - 2].eq_ignore_ascii_case(b"/mnt") { i - 6 } else { i - 2 };
            Some((start, i + 7))
        } else if at_token_start(bytes, i) && starts_with_ignore_case(&bytes[i..], b"/users/") {
            Some((i, i + 7))
        } else {
            None
        };
        if let Some((start, name_start)) = found {
            let end = name_end(bytes, name_start);
            if end > name_start {
                out.push_str(&text[copied..start]);
                out.push('~');
                copied = end;
                i = end;
                continue;
            }
        }
        i += 1;
    }
    out.push_str(&text[copied..]);
    out
}
