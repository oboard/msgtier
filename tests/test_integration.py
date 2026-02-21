import subprocess
import time
import urllib.request
import urllib.error
import sys
import os
import signal

def cleanup():
    print("Cleaning up existing processes...")
    subprocess.run(["pkill", "-f", "moon run cmd/main"], stderr=subprocess.DEVNULL)
    time.sleep(1)

def run_node(config_file, log_file):
    print(f"Starting node with {config_file}...")
    # Using moon run directly as requested for speed/simplicity
    cmd = ["moon", "run", "cmd/main", "--debug", "--", config_file]
    f = open(log_file, "w", buffering=1) # Line buffering
    process = subprocess.Popen(cmd, stdout=f, stderr=subprocess.STDOUT, text=True)
    return process, f

def test():
    cleanup()
    
    # Pre-build to avoid lock conflicts during startup
    print("Pre-building project...")
    # subprocess.run(["moon", "build", "cmd/main", "--debug"], check=True)
    
    p1 = None
    p2 = None
    f1 = None
    f2 = None
    
    try:

        p1, f1 = run_node("config/1.jsonc", "node1.log")
        print("Waiting for Node 1 to initialize...")
        time.sleep(5) # Give Node 1 time to pass the build check and start running
        
        p2, f2 = run_node("config/2.jsonc", "node2.log")
        print("Waiting for Node 2 to initialize...")
        time.sleep(5)
        
        print("Waiting 10 seconds for nodes to connect...")
        time.sleep(10)
        
        url = "http://127.0.0.1:9001/api/send"
        headers = {
            "target": "oboard-mac",
            "Content-Type": "text/plain"
        }
        data = "fastfetch".encode('utf-8')
        
        print(f"Sending request to {url}...")
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                status_code = response.getcode()
                response_text = response.read().decode('utf-8')
                
                print(f"Status Code: {status_code}")
                print(f"Response Text: {response_text}")
                
                if status_code == 200 and "error" not in response_text.lower() and len(response_text) > 0:
                    print("SUCCESS: Response received and looks valid.")
                    return True
                else:
                    print("FAILURE: Response indicates error or is empty.")
                    return False
        except urllib.error.HTTPError as e:
            print(f"FAILURE: HTTP Error: {e.code} - {e.read().decode('utf-8')}")
            return False
        except urllib.error.URLError as e:
            print(f"FAILURE: URL Error: {e.reason}")
            return False
        except Exception as e:
            print(f"FAILURE: Request failed: {e}")
            return False
            
    finally:
        print("Stopping nodes...")
        if p1: p1.terminate()
        if p2: p2.terminate()
        if f1: f1.close()
        if f2: f2.close()
        time.sleep(1)
        cleanup()

if __name__ == "__main__":
    if test():
        sys.exit(0)
    else:
        sys.exit(1)
