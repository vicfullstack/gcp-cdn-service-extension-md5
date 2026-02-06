FROM scratch
COPY md5_plugin/target/wasm32-wasip1/release/md5_auth_plugin.wasm plugin.wasm
