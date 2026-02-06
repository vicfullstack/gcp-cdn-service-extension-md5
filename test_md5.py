import hashlib
import time
import requests
import sys
import urllib3

# Suppress InsecureRequestWarning
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Configuration
LB_IP = "34.117.49.78"
SECRET_KEY = "my-secret-key"
TEST_PATH = "/index.html" 

def generate_url(ip, path, secret, timestamp=None, rand="12345", uid="0"):
    if timestamp is None:
        # Default to 1 hour in the future
        timestamp = int(time.time()) + 3600
    
    # Logic from Rust plugin:
    # string_to_hash = path + "-" + timestamp + "-" + rand + "-" + uid + "-" + secret
    string_to_hash = f"{path}-{timestamp}-{rand}-{uid}-{secret}"
    md5_hash = hashlib.md5(string_to_hash.encode('utf-8')).hexdigest()
    
    auth_key = f"{timestamp}-{rand}-{uid}-{md5_hash}"
    url = f"http://{ip}{path}?auth_key={auth_key}"
    
    print(f"Debug: String to hash: '{string_to_hash}'")
    print(f"Debug: Hash: {md5_hash}")
    
    return url

def test_request(name, url, expected_code):
    print(f"\n--- Test: {name} ---")
    print(f"URL: {url}")
    try:
        response = requests.get(url, timeout=5, verify=False)
        print(f"Status Code: {response.status_code}")
        print(f"Response Body: {response.text[:100]}...") 
        
        if response.status_code == expected_code:
            print("✅ PASS")
        elif expected_code == 200 and response.status_code == 404:
             print("✅ PASS (404 means Auth passed, backend file not found)")
        elif expected_code == 200 and response.status_code == 502:
             print("⚠️ PASS/WARN (502 means Auth passed, backend health check might be failing)")
        else:
            print(f"❌ FAIL (Expected {expected_code})")
            
    except Exception as e:
        print(f"❌ Error: {e}")

def main():
    print(f"Testing MD5 Auth on LB: {LB_IP}")
    
    # 1. Valid Request
    url_valid = generate_url(LB_IP, TEST_PATH, SECRET_KEY)
    test_request("Valid Token", url_valid, 200)
    
    # 2. Expired Token
    expired_ts = int(time.time()) - 3600 # 1 hour ago
    url_expired = generate_url(LB_IP, TEST_PATH, SECRET_KEY, timestamp=expired_ts)
    test_request("Expired Token", url_expired, 403)
    
    # 3. Invalid Secret (Wrong Hash)
    url_bad_secret = generate_url(LB_IP, TEST_PATH, "wrong-secret")
    test_request("Invalid Secret", url_bad_secret, 403)
    
    # 4. Modified Path (Hash Mismatch)
    valid_auth_key = generate_url(LB_IP, TEST_PATH, SECRET_KEY).split("auth_key=")[1]
    url_bad_path = f"http://{LB_IP}/other.txt?auth_key={valid_auth_key}"
    test_request("Path Mismatch", url_bad_path, 403)

if __name__ == "__main__":
    main()