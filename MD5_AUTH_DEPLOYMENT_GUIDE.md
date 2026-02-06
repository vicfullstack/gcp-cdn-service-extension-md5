# MD5 Authentication Service Extension Deployment Guide

This guide documents the development, infrastructure setup, and deployment of a Google Cloud Service Extension (Edge Extension) that implements MD5-based URL authentication.

## 1. Process Overview

Service Extensions (specifically [Edge Extensions](https://docs.cloud.google.com/service-extensions/docs/lb-extensions-overview?hl=en)) allow you to inject custom logic into the request processing path of a Google Cloud Application Load Balancer. This capability is powered by **WebAssembly (Wasm)** plugins running at the edge, which intercept traffic **before** it reaches your backend services or Cloud CDN cache.

In this implementation, we deploy a Rust-based Wasm plugin to an **Application Load Balancer**. This plugin intercepts incoming HTTP requests, extracts authentication tokens from the URL, and validates them against a secure MD5 signature logic. This pattern is widely used in media streaming (e.g., preventing hotlinking) to ensure only authorized users with valid, non-expired tokens can access content.

## 2. Solution Specification

The solution enforces a security policy where every request to the Load Balancer must include a valid `auth_key` query parameter. This key protects content by verifying both the expiration time and a digital signature.

**URL Format:**
```
http://<LB_IP>/<path>?auth_key=<timestamp>-<rand>-<uid>-<md5hash>
```

**Signature Logic:**
```
md5hash = MD5(/path-timestamp-rand-uid-secret_key)
```

## 3. Plugin Development

The logic is implemented in Rust using the `proxy-wasm` SDK, which compiles to a WebAssembly (Wasm) module.

### Core Logic (`md5_plugin/src/lib.rs`)

The plugin intercepts HTTP request headers and performs the following checks:
1.  **Extracts** the `auth_key` from the query string.
2.  **Parses** the key into its components: `timestamp`, `rand`, `uid`, and `hash`.
3.  **Validates Expiration**: Checks if the current time is greater than the provided `timestamp`.
4.  **Validates Signature**: Re-calculates the MD5 hash using the request path, parameters, and a shared `secret_key` (configured at deployment). If the calculated hash matches the provided hash, the request is allowed; otherwise, it is rejected with `403 Forbidden`.

### Dependencies (`md5_plugin/Cargo.toml`)
- `proxy-wasm`: Google's SDK for writing Wasm extensions.
- `md5`: For cryptographic hashing.
- `url`: For robust URL parsing.

## 4. Infrastructure Setup

Service Extensions require an **Application Load Balancer** with the **`EXTERNAL_MANAGED`** load balancing scheme. Classic external load balancers are not supported.

### Components Created
1.  **Managed Backend Service** (`nginx-uig-hk-managed`): 
    - Protocol: HTTP
    - Load Balancing Scheme: `EXTERNAL_MANAGED`
    - Backend: Instance Group `nginx-uig-hk`
2.  **URL Map** (`md5-lb-map`): Routes requests to the backend service.
3.  **Target HTTP Proxy** (`md5-lb-proxy`): Helper for the forwarding rule.
4.  **Forwarding Rule** (`md5-lb-forwarding-rule`): The entry point for traffic (IP: `34.117.49.78`).
5.  **Firewall Rule** (`allow-health-checks`): Allows Google health check probes (IP ranges `130.211.0.0/22`, `35.191.0.0/16`) to reach the backend VMs on port 80.

## 5. Deployment Steps

The deployment process is automated via `deploy.sh`. Key steps include:

1.  **Build Wasm**: Compiles the Rust code to the `wasm32-wasip1` target.
    ```bash
    cargo build --release --target wasm32-wasip1
    ```

2.  **Containerize**: Packages the `.wasm` file into a minimal Docker container (`FROM scratch`).

3.  **Upload**: Pushes the container image to Google Artifact Registry.
    ```bash
    docker push us-central1-docker.pkg.dev/vicdemo/service-extensions/md5-auth-plugin:v1
    ```

4.  **Create Plugin Resource**: Registers the plugin with Google Cloud Service Extensions.
    ```bash
    gcloud service-extensions wasm-plugins create md5-auth-plugin ...
    ```

5.  **Import Edge Extension**: Binds the plugin to the Load Balancer's forwarding rule using a YAML configuration.
    ```yaml
    name: md5-edge-extension
    forwardingRules:
    - projects/vicdemo/global/forwardingRules/md5-lb-forwarding-rule
    loadBalancingScheme: EXTERNAL_MANAGED
    extensionChains:
    - name: "md5-chain"
      matchCondition:
        celExpression: 'request.path.startsWith("/")'
      extensions:
      - name: 'md5-auth'
        service: .../wasmPlugins/md5-auth-plugin
        supportedEvents:
        - REQUEST_HEADERS
    ```

## 6. Verification

Verification was performed using a Python script (`test_md5.py`) that generates valid and invalid tokens.

**Test Cases:**
- **Valid Request**: `200 OK` (Signature matches, token not expired).
- **Expired Token**: `403 Forbidden` (Token timestamp is in the past).
- **Invalid Secret**: `403 Forbidden` (Signature mismatch due to wrong key).
- **Path Mismatch**: `403 Forbidden` (Signature valid for one file cannot be used for another).

### How to Generate a Token (Python Example)
```python
import hashlib
import time

def generate_url(ip, path, secret):
    # Timestamp: 1 hour in the future
    timestamp = int(time.time()) + 3600
    rand = "12345"
    uid = "0"
    
    # Signature String: /path-timestamp-rand-uid-secret
    # Note: Ensure 'path' starts with /
    string_to_hash = f"{path}-{timestamp}-{rand}-{uid}-{secret}"
    md5_hash = hashlib.md5(string_to_hash.encode('utf-8')).hexdigest()
    
    auth_key = f"{timestamp}-{rand}-{uid}-{md5_hash}"
    return f"http://{ip}{path}?auth_key={auth_key}"
```
