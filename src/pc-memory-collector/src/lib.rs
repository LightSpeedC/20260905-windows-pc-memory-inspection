//! rust-ai-pc-memory-collector: メモリの時系列収集。
//! 1 分ごとにシステム全体のメモリ、1 時間ごとに全プロセスの状態を SQLite に書き、毎日バックアップ（zip・100 世代）する。

pub mod backup;
pub mod collect;
pub mod config;
pub mod cpu;
pub mod db;
pub mod mask;
pub mod migrate;
pub mod request;
pub mod runner;
pub mod timeutil;
