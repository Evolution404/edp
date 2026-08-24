use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=src/bridge_libfuse.c");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }

    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
    let obj = out_dir.join("bridge_libfuse.o");
    let archive = out_dir.join("libedp_bridge_fuse.a");

    let cflags = Command::new("pkg-config")
        .args(["--cflags", "fuse"])
        .output()
        .expect("run pkg-config --cflags fuse");
    if !cflags.status.success() {
        panic!(
            "pkg-config could not find macFUSE: {}",
            String::from_utf8_lossy(&cflags.stderr)
        );
    }

    let mut cc = Command::new("cc");
    cc.arg("-c")
        .arg("src/bridge_libfuse.c")
        .arg("-o")
        .arg(&obj)
        .arg("-O2")
        .arg("-fPIC");
    for flag in String::from_utf8_lossy(&cflags.stdout).split_whitespace() {
        cc.arg(flag);
    }
    let status = cc.status().expect("compile bridge_libfuse.c");
    assert!(status.success(), "failed to compile libfuse bridge shim");

    let status = Command::new("ar")
        .arg("rcs")
        .arg(&archive)
        .arg(&obj)
        .status()
        .expect("archive bridge shim");
    assert!(status.success(), "failed to archive libfuse bridge shim");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=static=edp_bridge_fuse");

    let libs = Command::new("pkg-config")
        .args(["--libs", "fuse"])
        .output()
        .expect("run pkg-config --libs fuse");
    if !libs.status.success() {
        panic!(
            "pkg-config could not resolve macFUSE libraries: {}",
            String::from_utf8_lossy(&libs.stderr)
        );
    }
    let mut iter = String::from_utf8_lossy(&libs.stdout)
        .split_whitespace()
        .map(str::to_string)
        .peekable();
    while let Some(flag) = iter.next() {
        if let Some(path) = flag.strip_prefix("-L") {
            println!("cargo:rustc-link-search=native={path}");
        } else if let Some(lib) = flag.strip_prefix("-l") {
            println!("cargo:rustc-link-lib={lib}");
        } else if flag == "-framework" {
            if let Some(framework) = iter.next() {
                println!("cargo:rustc-link-lib=framework={framework}");
            }
        } else if let Some(path) = flag.strip_prefix("-F") {
            println!("cargo:rustc-link-search=framework={path}");
        }
    }
}
