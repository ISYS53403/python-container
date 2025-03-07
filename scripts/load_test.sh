#!/usr/bin/env python3
import argparse
import concurrent.futures
import requests
import time
import sys
import statistics
from datetime import datetime
import random

# Terminal colors for nice output
class Colors:
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    BLUE = '\033[94m'
    BOLD = '\033[1m'
    END = '\033[0m'

def send_request(url, session, request_id):
    """Send a single request and measure response time"""
    start_time = time.time()
    try:
        response = session.get(url)
        elapsed = time.time() - start_time
        status = response.status_code
        
        # Add jitter to make spikes more visible
        if random.random() < 0.1:  # 10% of requests get additional processing
            time.sleep(random.uniform(0.1, 0.5))
            
        return {
            'request_id': request_id,
            'status': status,
            'time': elapsed
        }
    except requests.RequestException as e:
        elapsed = time.time() - start_time
        return {
            'request_id': request_id,
            'status': 'Error',
            'time': elapsed,
            'error': str(e)
        }

def generate_load(url, concurrent_users, duration, ramp_up=0):
    """Generate load with specified number of concurrent users"""
    print(f"{Colors.BLUE}{Colors.BOLD}Starting load test against {url}{Colors.END}")
    print(f"Concurrent users: {concurrent_users}, Duration: {duration}s")
    
    if ramp_up > 0:
        print(f"Ramping up users over {ramp_up} seconds")
    
    # Statistics to track
    total_requests = 0
    successful_requests = 0
    response_times = []
    status_counts = {}
    start_time = time.time()
    end_time = start_time + duration
    
    # Create a session for connection pooling
    session = requests.Session()
    
    # Track progress for periodic updates
    last_update_time = start_time
    update_interval = 5  # seconds between progress updates
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrent_users) as executor:
        futures = []
        request_id = 0
        
        # Initial batch of requests
        current_users = 1 if ramp_up > 0 else concurrent_users
        for i in range(current_users):
            futures.append(executor.submit(send_request, url, session, request_id))
            request_id += 1
            
        # Continue sending requests until duration is reached
        while time.time() < end_time:
            # Check for completed requests and replace them
            done, not_done = concurrent.futures.wait(
                futures, 
                timeout=0.1,
                return_when=concurrent.futures.FIRST_COMPLETED
            )
            
            # Process completed requests
            for future in done:
                result = future.result()
                total_requests += 1
                
                # Track status codes
                status = result['status']
                if status not in status_counts:
                    status_counts[status] = 0
                status_counts[status] += 1
                
                if status == 200:
                    successful_requests += 1
                    response_times.append(result['time'])
                
                # Replace with a new request if we're still within duration
                if time.time() < end_time:
                    # Calculate current user count based on ramp-up
                    if ramp_up > 0:
                        elapsed = time.time() - start_time
                        current_users = min(int((elapsed / ramp_up) * concurrent_users) + 1, concurrent_users)
                    
                    # Only add a new request if we're within the current user limit
                    if len(not_done) < current_users - 1:
                        futures.add(executor.submit(send_request, url, session, request_id))
                        request_id += 1
                
                # Provide periodic updates
                current_time = time.time()
                if current_time - last_update_time >= update_interval:
                    elapsed = current_time - start_time
                    remaining = max(0, duration - elapsed)
                    _print_progress(elapsed, remaining, total_requests, 
                                   successful_requests, response_times, status_counts)
                    last_update_time = current_time
                
            # Sleep a tiny bit to reduce CPU usage
            time.sleep(0.01)
    
    # Final stats
    elapsed = time.time() - start_time
    _print_progress(elapsed, 0, total_requests, successful_requests, 
                   response_times, status_counts, final=True)
    
def _print_progress(elapsed, remaining, total_requests, successful_requests, 
                   response_times, status_counts, final=False):
    """Print current progress and stats"""
    # Clear previous line for updates
    if not final:
        sys.stdout.write("\033[K")  # Clear line
    
    # Calculate metrics
    success_rate = (successful_requests / total_requests * 100) if total_requests > 0 else 0
    requests_per_second = total_requests / elapsed if elapsed > 0 else 0
    
    # Response time stats
    if response_times:
        avg_response_time = sum(response_times) / len(response_times)
        if len(response_times) > 1:
            std_dev = statistics.stdev(response_times)
        else:
            std_dev = 0
        p95 = sorted(response_times)[int(len(response_times) * 0.95)] if len(response_times) > 10 else max(response_times)
    else:
        avg_response_time = 0
        std_dev = 0
        p95 = 0
    
    # Format the time
    if final:
        title = f"{Colors.BOLD}{Colors.BLUE}Test completed in {elapsed:.1f}s{Colors.END}"
    else:
        title = f"{Colors.BOLD}Running for {elapsed:.1f}s (remaining: {remaining:.1f}s){Colors.END}"
    
    # Status color based on success rate
    status_color = Colors.GREEN if success_rate > 95 else Colors.YELLOW if success_rate > 80 else Colors.RED
        
    print(f"\r{title}")
    print(f"  Requests: {total_requests} total, {status_color}{successful_requests} successful ({success_rate:.1f}%){Colors.END}")
    print(f"  Rate: {requests_per_second:.1f} requests/second")
    
    # Status code breakdown
    status_display = "  Status codes: "
    for status, count in status_counts.items():
        if status == 200:
            status_display += f"{Colors.GREEN}200: {count}{Colors.END}, "
        elif isinstance(status, int) and 400 <= status < 500:
            status_display += f"{Colors.YELLOW}{status}: {count}{Colors.END}, "
        elif isinstance(status, int) and status >= 500:
            status_display += f"{Colors.RED}{status}: {count}{Colors.END}, "
        else:
            status_display += f"{Colors.RED}{status}: {count}{Colors.END}, "
    print(status_display.rstrip(", "))
    
    # Response time stats
    if response_times:
        print(f"  Response time: avg={avg_response_time*1000:.1f}ms, stdev={std_dev*1000:.1f}ms, p95={p95*1000:.1f}ms")
    
    if not final:
        print(f"  {Colors.YELLOW}Press Ctrl+C to stop early{Colors.END}")
    else:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"\n{Colors.BOLD}Test completed at {timestamp}{Colors.END}")

def main():
    parser = argparse.ArgumentParser(description="Generate load on a web application")
    parser.add_argument("url", help="Target URL to test")
    parser.add_argument("--users", "-u", type=int, default=10, help="Number of concurrent users")
    parser.add_argument("--duration", "-d", type=int, default=60, help="Test duration in seconds")
    parser.add_argument("--ramp-up", "-r", type=int, default=0, 
                        help="Ramp-up time in seconds (gradually increases users)")
    
    args = parser.parse_args()
    
    try:
        generate_load(args.url, args.users, args.duration, args.ramp_up)
    except KeyboardInterrupt:
        print(f"\n{Colors.YELLOW}Test stopped by user.{Colors.END}")
        sys.exit(0)

if __name__ == "__main__":
    main()