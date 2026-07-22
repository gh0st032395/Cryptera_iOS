// Entry point della CLI uniffi-bindgen, invocata da scripts/build-xcframework.sh.
// Vive nel crate così che la versione del generatore sia sempre identica a
// quella della libreria uniffi usata dai proc-macro: un disallineamento fra le
// due produce binding che compilano ma falliscono a runtime.
fn main() {
    uniffi::uniffi_bindgen_main()
}
