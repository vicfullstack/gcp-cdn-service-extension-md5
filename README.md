# MD5 鉴权服务扩展 (Service Extension) 部署指南

本指南详细介绍了如何开发、部署和配置 Google Cloud Service Extension（边缘扩展），以实现基于 MD5 的 URL 鉴权功能。

## 1. 流程概述

Service Extensions（特别是 [Edge Extensions](https://docs.cloud.google.com/service-extensions/docs/lb-extensions-overview?hl=en)）允许您将自定义逻辑注入到 Google Cloud 应用负载均衡器 (Application Load Balancer) 的请求处理路径中。该功能基于 **WebAssembly (Wasm)** 技术，插件运行在边缘节点，能够在流量到达后端服务或 Cloud CDN 缓存**之前**进行拦截和处理。

在本方案中，我们将一个基于 Rust 开发的 Wasm 插件部署到 **应用负载均衡器** 上。该插件会拦截所有传入的 HTTP 请求，解析 URL 中的鉴权 Token，并基于安全的 MD5 签名算法进行校验。这种模式在流媒体服务中非常常见（例如防盗链），用于确保只有持有有效且未过期 Token 的用户才能访问资源。

## 2. 方案规范

本方案强制执行严格的安全策略：所有发往负载均衡器的请求都必须携带有效的 `auth_key` 查询参数。系统将校验该参数的过期时间以及数字签名的有效性。

**URL 格式：**
```
http://<LB_IP>/<path>?auth_key=<timestamp>-<rand>-<uid>-<md5hash>
```

**签名算法：**
```
md5hash = MD5(/path-timestamp-rand-uid-secret_key)
```

## 3. 插件开发

插件逻辑使用 Rust 语言配合 `proxy-wasm` SDK 开发，最终编译为 WebAssembly (Wasm) 模块。

### 核心逻辑 (`md5_plugin/src/lib.rs`)

插件会拦截 HTTP 请求头 (Request Headers) 并执行以下步骤：
1.  **提取参数**：从 URL 查询字符串中获取 `auth_key`。
2.  **解析 Token**：将 `auth_key` 拆解为 `timestamp`（过期时间戳）、`rand`（随机数）、`uid`（用户ID）和 `hash`（签名哈希）。
3.  **校验过期时间**：检查当前系统时间是否已超过 Token 中的 `timestamp`。
4.  **校验数字签名**：使用请求路径、Token 参数以及预共享的 `secret_key`（部署时配置）重新计算 MD5 哈希值。
    - **通过**：计算结果与 URL 中的哈希一致，放行请求。
    - **拒绝**：计算结果不一致，返回 `403 Forbidden`。

### 项目依赖 (`md5_plugin/Cargo.toml`)
- `proxy-wasm`: Google Cloud 扩展的标准 Wasm SDK。
- `md5`: 提供 MD5 哈希计算能力。
- `url`: 用于标准化的 URL 解析。

## 4. 基础设施配置

Service Extensions 必须配合 **应用负载均衡器 (Application Load Balancer)** 使用，且负载均衡方案 (Load Balancing Scheme) 必须为 **`EXTERNAL_MANAGED`**。传统的 Classic Load Balancer 不支持此功能。

### 已部署组件
1.  **托管后端服务 (Managed Backend Service)**: `nginx-uig-hk-managed`
    - 协议: HTTP
    - 模式: `EXTERNAL_MANAGED`
    - 后端: 实例组 `nginx-uig-hk`
2.  **URL 映射 (URL Map)**: `md5-lb-map` (负责路由请求)。
3.  **目标 HTTP 代理 (Target HTTP Proxy)**: `md5-lb-proxy`。
4.  **转发规则 (Forwarding Rule)**: `md5-lb-forwarding-rule` (流量入口 IP: `34.117.49.78`)。
5.  **防火墙规则**: `allow-health-checks` (放行 Google 健康检查 IP 段 `130.211.0.0/22`, `35.191.0.0/16` 至后端 80 端口)。

## 5. 部署步骤

所有部署操作已封装在 `deploy.sh` 脚本中，主要步骤如下：

1.  **编译 Wasm 模块**：将 Rust 代码编译为 `wasm32-wasip1` 目标格式。
    ```bash
    cargo build --release --target wasm32-wasip1
    ```

2.  **构建容器镜像**：将 `.wasm` 文件封装到最小化的 Docker 容器中（基于 `scratch` 镜像）。

3.  **推送镜像**：将容器镜像上传至 Google Artifact Registry。
    ```bash
    docker push us-central1-docker.pkg.dev/vicdemo/service-extensions/md5-auth-plugin:v1
    ```

4.  **注册插件资源**：在 Google Cloud Service Extensions 中注册该插件。
    ```bash
    gcloud service-extensions wasm-plugins create md5-auth-plugin ...
    ```

5.  **配置边缘扩展**：通过 YAML 配置文件，将插件绑定到负载均衡器的转发规则上，使其生效。
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

## 6. 验证方法

我们提供了一个 Python 脚本 (`test_md5.py`) 用于生成测试 Token 并验证鉴权逻辑。

**测试场景：**
- **✅ 有效请求**：返回 `200 OK`（签名正确且未过期）。
- **❌ 过期 Token**：返回 `403 Forbidden`（Token 时间戳早于当前时间）。
- **❌ 密钥错误**：返回 `403 Forbidden`（签名计算不匹配）。
- **❌ 路径不匹配**：返回 `403 Forbidden`（Token 仅对特定路径有效，防止重放攻击）。

### Token 生成示例 (Python)
```python
import hashlib
import time

def generate_url(ip, path, secret):
    # 设置过期时间为当前时间 + 1小时
    timestamp = int(time.time()) + 3600
    rand = "12345"
    uid = "0"
    
    # 拼接签名字符串：/path-timestamp-rand-uid-secret
    # 注意：path 必须包含开头的斜杠 /
    string_to_hash = f"{path}-{timestamp}-{rand}-{uid}-{secret}"
    
    # 计算 MD5
    md5_hash = hashlib.md5(string_to_hash.encode('utf-8')).hexdigest()
    
    # 拼接最终 URL
    auth_key = f"{timestamp}-{rand}-{uid}-{md5_hash}"
    return f"http://{ip}{path}?auth_key={auth_key}"
```
