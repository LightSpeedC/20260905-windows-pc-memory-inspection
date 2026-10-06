// src/scripts/20_migrate/ver_NNNNNN/*.sql を、実行ファイルに埋め込む。
// サービスは単独の実行ファイルで動くため、実行時にファイルを読まない。
use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let dir = manifest.join("..").join("scripts").join("20_migrate");
    println!("cargo:rerun-if-changed={}", dir.display());

    let mut versions: Vec<(u32, String, Vec<(String, PathBuf)>)> = Vec::new();
    if let Ok(entries) = fs::read_dir(&dir) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(num) = name.strip_prefix("ver_") else { continue };
            if num.len() != 6 || !num.bytes().all(|b| b.is_ascii_digit()) {
                continue;
            }
            let seq: u32 = num.parse().unwrap();
            let mut files: Vec<(String, PathBuf)> = fs::read_dir(entry.path())
                .unwrap()
                .flatten()
                .filter(|f| f.file_name().to_string_lossy().ends_with(".sql"))
                .map(|f| (f.file_name().to_string_lossy().into_owned(), f.path()))
                .collect();
            files.sort();
            for (_, p) in &files {
                println!("cargo:rerun-if-changed={}", p.display());
            }
            versions.push((seq, name, files));
        }
    }
    versions.sort();

    let mut out = String::from("pub static EMBEDDED: &[(u32, &str, &[(&str, &str)])] = &[\n");
    for (seq, name, files) in &versions {
        out.push_str(&format!("    ({seq}, {name:?}, &[\n"));
        for (fname, path) in files {
            out.push_str(&format!("        ({fname:?}, include_str!({:?})),\n", path.to_string_lossy()));
        }
        out.push_str("    ]),\n");
    }
    out.push_str("];\n");
    fs::write(PathBuf::from(env::var("OUT_DIR").unwrap()).join("migrations.rs"), out).unwrap();
}
