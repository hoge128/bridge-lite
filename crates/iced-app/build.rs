fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rerun-if-changed=macos/cgimage_shim.cpp");
        cc::Build::new()
            .cpp(true)
            .flag_if_supported("-std=c++17")
            .flag_if_supported("-fexceptions")
            .file("macos/cgimage_shim.cpp")
            .compile("cgimage_shim");
        println!("cargo:rustc-link-lib=framework=ImageIO");
    }
}
