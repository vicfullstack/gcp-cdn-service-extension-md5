use log::{info, error, debug};
use proxy_wasm::traits::*;
use proxy_wasm::types::*;
use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};
use url::Url;
use md5;

// Define the structure for our plugin
struct Md5AuthPlugin {
    // Shared secret for MD5 hashing
    secret: String,
}

// Define the root context, which can handle configuration
struct Md5AuthPluginRoot {
    secret: String,
}

impl Context for Md5AuthPluginRoot {}

impl RootContext for Md5AuthPluginRoot {
    fn on_configure(&mut self, _: usize) -> bool {
        if let Some(config_bytes) = self.get_plugin_configuration() {
            // Assume config is just the secret string for simplicity
            match String::from_utf8(config_bytes) {
                Ok(s) => {
                    self.secret = s.trim().to_string();
                    info!("Plugin configured with secret: {}", self.secret);
                }
                Err(_) => {
                    error!("Invalid configuration: expected UTF-8 string");
                    return false;
                }
            }
        }
        true
    }

    fn create_http_context(&self, _: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(Md5AuthPlugin {
            secret: self.secret.clone(),
        }))
    }

    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }
}

impl Context for Md5AuthPlugin {}

impl HttpContext for Md5AuthPlugin {
    fn on_http_request_headers(&mut self, _: usize, _: bool) -> Action {
        let path = match self.get_http_request_header(":path") {
            Some(p) => p,
            None => {
                self.send_http_response(400, vec![], Some(b"Missing :path header"));
                return Action::Pause;
            }
        };

        // Construct a full URL to parse query parameters easily
        // We use localhost as base because we only care about the path and query
        let pseudo_url = format!("http://localhost{}", path);
        let parsed_url = match Url::parse(&pseudo_url) {
            Ok(u) => u,
            Err(_) => {
                self.send_http_response(400, vec![], Some(b"Invalid URL"));
                return Action::Pause;
            }
        };

        let query_params: HashMap<_, _> = parsed_url.query_pairs().into_owned().collect();

        // Check for auth_key parameter
        // Format: auth_key=<timestamp>-<rand>-<uid>-<md5hash>
        let auth_key = match query_params.get("auth_key") {
            Some(k) => k,
            None => {
                self.send_http_response(403, vec![], Some(b"Missing auth_key"));
                return Action::Pause;
            }
        };

        // Parse auth_key components
        let parts: Vec<&str> = auth_key.split('-').collect();
        if parts.len() != 4 {
            self.send_http_response(403, vec![], Some(b"Invalid auth_key format"));
            return Action::Pause;
        }

        let timestamp_str = parts[0];
        let rand_str = parts[1];
        let uid_str = parts[2];
        let provided_hash = parts[3];

        // 1. Validate Timestamp
        let timestamp: u64 = match timestamp_str.parse() {
            Ok(t) => t,
            Err(_) => {
                self.send_http_response(403, vec![], Some(b"Invalid timestamp"));
                return Action::Pause;
            }
        };

        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        
        // Expiration check (e.g., token valid if timestamp is in the future)
        // Or if timestamp is creation time, check if now < timestamp + ttl
        // Assuming 'timestamp' in the URL is the EXPIRATION time (standard for many CDNs)
        if now > timestamp {
             self.send_http_response(403, vec![], Some(b"Token expired"));
             return Action::Pause;
        }

        // 2. Validate Hash
        // Construction: path-timestamp-rand-uid-secret
        // Note: The path usually does NOT include the query string.
        let path_without_query = parsed_url.path();
        
        // Construct the string to hash. 
        // Logic: path + "-" + timestamp + "-" + rand + "-" + uid + "-" + secret
        // This is a common pattern. Adjust logic here if strict requirements differ.
        let string_to_hash = format!("{}-{}-{}-{}-{}", path_without_query, timestamp_str, rand_str, uid_str, self.secret);
        
        let digest = md5::compute(string_to_hash);
        let expected_hash = format!("{:x}", digest);

        if provided_hash != expected_hash {
            info!("Hash mismatch. Expected: {}, Got: {}", expected_hash, provided_hash);
            self.send_http_response(403, vec![], Some(b"Invalid signature"));
            return Action::Pause;
        }

        // 3. (Optional) Strip auth_key from request before forwarding to backend
        // This improves cache hit ratio if the backend doesn't need the token.
        // For now, we leave it as is or we can redirect/rewrite. 
        // Let's just allow the request to proceed.

        Action::Continue
    }
}

proxy_wasm::main! {{
    proxy_wasm::set_log_level(LogLevel::Trace);
    proxy_wasm::set_root_context(|_| -> Box<dyn RootContext> {
        Box::new(Md5AuthPluginRoot {
            secret: String::new(), // Initial empty, set via config
        })
    });
}}
