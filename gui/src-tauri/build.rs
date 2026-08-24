fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .file("native/service_management.m")
            .flag("-fobjc-arc")
            .compile("edp_service_management");
        println!("cargo:rustc-link-lib=framework=Foundation");
        println!("cargo:rustc-link-lib=framework=ServiceManagement");
        println!("cargo:rerun-if-changed=native/service_management.m");
    }
    tauri_build::build()
}
