fn main() {
    let bridges = vec!["src/lib.rs"];
    for path in &bridges {
        println!("cargo:rerun-if-changed={}", path);
    }
    swift_bridge_build::parse_bridges(bridges)
        .write_all_concatenated("generated", "bridge-ffi");
}
