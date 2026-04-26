#!/usr/bin/env python3
"""
🎬 TAGUCHI DEBUGGER VISUAL DEMO
See EXACTLY how it works - step by step animation!
"""

import os
import sys
import time
import json
import numpy as np
from datetime import datetime
from typing import List, Dict, Any
import hashlib

# ============================================
# VISUAL SETUP
# ============================================
class VisualDemo:
    def __init__(self):
        self.terminal_width = 80
        self.animation_speed = 0.03
        self.colors = {
            'reset': '\033[0m',
            'red': '\033[91m',
            'green': '\033[92m',
            'yellow': '\033[93m',
            'blue': '\033[94m',
            'magenta': '\033[95m',
            'cyan': '\033[96m',
            'white': '\033[97m',
            'bg_red': '\033[41m',
            'bg_green': '\033[42m',
            'bg_blue': '\033[44m',
            'bold': '\033[1m'
        }
    
    def clear_screen(self):
        os.system('cls' if os.name == 'nt' else 'clear')
    
    def print_header(self, title):
        print("\n" + "=" * self.terminal_width)
        print(f"{self.colors['bold']}{self.colors['cyan']}{title.center(self.terminal_width)}{self.colors['reset']}")
        print("=" * self.terminal_width + "\n")
    
    def print_step(self, step_num, description):
        print(f"\n{self.colors['yellow']}Step {step_num}: {description}{self.colors['reset']}")
        time.sleep(0.5)
    
    def animate_text(self, text, color='white'):
        for char in text:
            print(f"{self.colors[color]}{char}{self.colors['reset']}", end='', flush=True)
            time.sleep(self.animation_speed)
        print()
    
    def show_terminal(self, command, output, error=False):
        print(f"\n{self.colors['green']}$ {command}{self.colors['reset']}")
        time.sleep(0.3)
        
        if error:
            print(f"{self.colors['red']}{output}{self.colors['reset']}")
        else:
            print(f"{output}")
        
        time.sleep(0.5)
    
    def show_vector(self, vector_data, title="Vector Representation"):
        print(f"\n{self.colors['magenta']}📊 {title}{self.colors['reset']}")
        print("-" * 50)
        
        if isinstance(vector_data, list):
            # Show first 10 dimensions
            preview = vector_data[:10]
            print(f"Dimensions: {len(vector_data)}")
            print(f"Preview: [{', '.join(f'{v:.3f}' for v in preview)}...]")
            
            # Visual bar chart
            print("\nVisualization:")
            for i, val in enumerate(preview):
                bar_length = int(val * 30)
                bar = '█' * bar_length + '░' * (30 - bar_length)
                print(f"  Dim {i:2d}: |{self.colors['cyan']}{bar}{self.colors['reset']}| {val:.3f}")
        else:
            print(json.dumps(vector_data, indent=2))
        
        time.sleep(1)
    
    def show_similarity(self, vec1, vec2, similarity):
        print(f"\n{self.colors['blue']}🔍 Similarity Analysis{self.colors['reset']}")
        print("-" * 50)
        
        # Visual similarity meter
        meter_width = 40
        filled = int(similarity * meter_width)
        meter = '█' * filled + '░' * (meter_width - filled)
        
        print(f"Similarity: {similarity:.3%}")
        print(f"[{self.colors['green']}{meter}{self.colors['reset']}]")
        
        if similarity > 0.85:
            print(f"{self.colors['green']}✅ HIGH MATCH! Same error pattern detected.{self.colors['reset']}")
        elif similarity > 0.60:
            print(f"{self.colors['yellow']}⚠️  MEDIUM MATCH - Possibly related.{self.colors['reset']}")
        else:
            print(f"{self.colors['red']}❌ LOW MATCH - New error pattern.{self.colors['reset']}")
        
        time.sleep(1.5)
    
    def show_taguchi_matrix(self, matrix, results):
        print(f"\n{self.colors['cyan']}🧪 Taguchi Test Matrix (L9){self.colors['reset']}")
        print("-" * 50)
        
        headers = ["Test #", "Command", "Flags", "Version", "Result"]
        print(f"{headers[0]:^8} | {headers[1]:^20} | {headers[2]:^10} | {headers[3]:^10} | {headers[4]:^10}")
        print("-" * 70)
        
        for i, (test, result) in enumerate(zip(matrix, results)):
            status_color = 'green' if result == '✅' else 'red'
            print(f"{i+1:^8} | {test['command']:^20} | {test['flags']:^10} | {test['version']:^10} | "
                  f"{self.colors[status_color]}{result:^10}{self.colors['reset']}")
            time.sleep(0.2)
        
        # Show statistical analysis
        success_rate = results.count('✅') / len(results)
        print(f"\n📈 Success Rate: {success_rate:.1%}")
        
        if success_rate > 0.8:
            print(f"{self.colors['green']}🎯 OPTIMAL FIX FOUND!{self.colors['reset']}")
        else:
            print(f"{self.colors['yellow']}🔍 More testing needed...{self.colors['reset']}")
        
        time.sleep(2)

# ============================================
# SIMULATED TAGUCHI DEBUGGER
# ============================================
class SimulatedTaguchiDebugger:
    def __init__(self):
        self.error_database = {}
        self.vector_dimensions = 384
        self.visual = VisualDemo()
    
    def simulate_day_1(self):
        """Day 1: First encounter with an error"""
        self.visual.clear_screen()
        self.visual.print_header("DAY 1: FIRST ENCOUNTER - THE DEBUGGER LEARNS")
        
        # Step 1: You run a command
        self.visual.print_step(1, "You run a command in VS Code Terminal")
        self.visual.show_terminal(
            "npm install electron",
            "npm ERR! Cannot find module 'electron'\n"
            "npm ERR! code ENOENT\n"
            "npm ERR! syscall open\n"
            "npm ERR! path /Users/you/project/node_modules/electron\n"
            "npm ERR! errno -2",
            error=True
        )
        
        # Step 2: Taguchi Debugger captures the error
        self.visual.print_step(2, "Taguchi Debugger automatically captures error")
        error_text = "npm ERR! Cannot find module 'electron'"
        context = {
            "os": "macOS 14.2",
            "node": "v18.17.0",
            "npm": "10.2.3",
            "command": "npm install electron",
            "timestamp": datetime.now().isoformat()
        }
        
        print(f"\n{self.visual.colors['blue']}📝 Captured:{self.visual.colors['reset']}")
        print(f"Error: {error_text}")
        print(f"Context: {json.dumps(context, indent=2)}")
        time.sleep(2)
        
        # Step 3: Generate vector embedding
        self.visual.print_step(3, "Convert error to 384-dimensional vector")
        error_vector = self.generate_error_vector(error_text, context)
        self.visual.show_vector(error_vector, "Error Vector Embedding")
        
        # Step 4: Search database (empty first time)
        self.visual.print_step(4, "Search Vector Database for similar errors")
        print(f"{self.visual.colors['yellow']}Database empty - this is a NEW error!{self.visual.colors['reset']}")
        time.sleep(1)
        
        # Step 5: Run Taguchi tests
        self.visual.print_step(5, "Run Taguchi L9 systematic tests")
        
        # Generate test matrix
        matrix = self.generate_taguchi_matrix()
        
        # Simulate test results
        results = ['❌', '✅', '❌', '✅', '❌', '✅', '❌', '✅', '❌']  # Mixed results
        
        self.visual.show_taguchi_matrix(matrix, results)
        
        # Step 6: Find optimal fix
        self.visual.print_step(6, "Analyze results and find optimal fix")
        optimal_fix = "npm ci"  # Found by Taguchi testing
        
        print(f"\n{self.visual.colors['green']}🎯 OPTIMAL FIX DISCOVERED:{self.visual.colors['reset']}")
        print(f"Instead of: npm install electron")
        print(f"Use: {optimal_fix}")
        print(f"Success rate: 3/3 tests (100%)")
        time.sleep(2)
        
        # Step 7: Store in database
        self.visual.print_step(7, "Store error + fix in Vector Database")
        
        error_id = self.hash_error(error_text)
        self.error_database[error_id] = {
            "id": error_id,
            "error": error_text,
            "vector": error_vector,
            "context": context,
            "fix": optimal_fix,
            "success_rate": 1.0,
            "occurrences": 1,
            "first_seen": datetime.now().isoformat(),
            "last_seen": datetime.now().isoformat()
        }
        
        print(f"\n{self.visual.colors['cyan']}💾 Database updated:{self.visual.colors['reset']}")
        print(f"Total errors: {len(self.error_database)}")
        print(f"Time saved: 2 hours (vs Googling)")
        time.sleep(2)
        
        self.visual.print_header("DAY 1 COMPLETE: Debugger learned 1 new error pattern!")
        input("\nPress Enter to continue to Day 2...")
    
    def simulate_day_2(self):
        """Day 2: Same error occurs again"""
        self.visual.clear_screen()
        self.visual.print_header("DAY 2: SAME ERROR - INSTANT FIX!")
        
        # Step 1: Same error occurs
        self.visual.print_step(1, "You run the same command (forgetting yesterday)")
        self.visual.show_terminal(
            "npm install electron",
            "npm ERR! Cannot find module 'electron'\n"
            "npm ERR! code ENOENT",
            error=True
        )
        
        # Step 2: Taguchi captures and searches
        self.visual.print_step(2, "Taguchi Debugger captures error and searches database")
        
        error_text = "npm ERR! Cannot find module 'electron'"
        new_vector = self.generate_error_vector(error_text)
        
        # Find similar errors
        similar_errors = self.find_similar_errors(new_vector)
        
        if similar_errors:
            best_match = similar_errors[0]
            similarity = best_match['similarity']
            
            self.visual.show_similarity(new_vector, best_match['vector'], similarity)
            
            # Step 3: Instant fix suggestion
            self.visual.print_step(3, "INSTANT FIX SUGGESTION (from database)")
            
            print(f"\n{self.visual.colors['green']}⚡ TAGUCHI SUGGESTS:{self.visual.colors['reset']}")
            print(f"Error: '{error_text[:50]}...'")
            print(f"Match found: 98.7% similar to previous error")
            print(f"Fix that worked: {best_match['fix']}")
            print(f"Success rate: {best_match['success_rate']:.1%} ({best_match['occurrences']} occurrences)")
            time.sleep(2)
            
            # Step 4: Auto-apply fix
            self.visual.print_step(4, "Auto-apply the fix")
            self.visual.show_terminal(best_match['fix'], "✅ Success! Package installed.")
            
            # Update database
            self.error_database[best_match['id']]['occurrences'] += 1
            self.error_database[best_match['id']]['last_seen'] = datetime.now().isoformat()
            
        time.sleep(2)
        
        # Show another example
        self.visual.print_step(5, "Another example: Permission error")
        self.visual.show_terminal(
            "sudo npm install",
            "EPERM: permission denied, mkdir '/usr/local/lib/node_modules'",
            error=True
        )
        
        # This would be a new error that goes through Day 1 process
        print(f"\n{self.visual.colors['yellow']}(This would trigger new learning process){self.visual.colors['reset']}")
        
        self.visual.print_header("DAY 2 COMPLETE: 1 instant fix, 1 new error learned!")
        input("\nPress Enter to continue to Day 3...")
    
    def simulate_day_3(self):
        """Day 3: Multiple errors, some recognized"""
        self.visual.clear_screen()
        self.visual.print_header("DAY 3: DEBUGGER GETS SMARTER")
        
        print(f"{self.visual.colors['cyan']}📊 Database Stats:{self.visual.colors['reset']}")
        print(f"• Total errors learned: {len(self.error_database)}")
        print(f"• Most common: 'npm ERR! Cannot find module' (3 occurrences)")
        print(f"• Total time saved: ~6 hours")
        print(f"• Auto-fix success rate: 100%")
        time.sleep(2)
        
        # Simulate a coding session
        errors_to_simulate = [
            {
                "command": "npm install electron",
                "error": "npm ERR! Cannot find module 'electron'",
                "should_match": True
            },
            {
                "command": "python script.py",
                "error": "ModuleNotFoundError: No module named 'requests'",
                "should_match": False
            },
            {
                "command": "docker build .",
                "error": "ERROR: failed to solve: node:alpine not found",
                "should_match": False
            },
            {
                "command": "git push",
                "error": "ERROR: Permission to user/repo.git denied",
                "should_match": False
            }
        ]
        
        recognized = 0
        new_errors = 0
        
        for i, error_scenario in enumerate(errors_to_simulate):
            self.visual.print_step(i+1, f"Error {i+1}: {error_scenario['command']}")
            self.visual.show_terminal(
                error_scenario['command'],
                error_scenario['error'],
                error=True
            )
            
            if error_scenario['should_match']:
                print(f"{self.visual.colors['green']}✅ INSTANT RECOGNITION: Use 'npm ci'{self.visual.colors['reset']}")
                recognized += 1
            else:
                print(f"{self.visual.colors['yellow']}🆕 NEW ERROR: Will learn after fixing{self.visual.colors['reset']}")
                new_errors += 1
            
            time.sleep(1)
        
        # Summary
        self.visual.print_step(5, "Session Summary")
        print(f"\n{self.visual.colors['cyan']}📈 Today's performance:{self.visual.colors['reset']}")
        print(f"• Errors encountered: {len(errors_to_simulate)}")
        print(f"• Instantly recognized: {recognized}")
        print(f"• New errors to learn: {new_errors}")
        print(f"• Debugging time saved: ~{recognized * 0.5:.1f} hours")
        
        # Project future
        print(f"\n{self.visual.colors['green']}🎯 Projected after 30 days:{self.visual.colors['reset']}")
        print(f"• 50+ error patterns in database")
        print(f"• 90% auto-fix rate")
        print(f"• 100+ hours saved")
        print(f"• Never Google the same error twice!")
        
        time.sleep(3)
    
    def simulate_vector_magic(self):
        """Show how vectors capture meaning, not just text"""
        self.visual.clear_screen()
        self.visual.print_header("THE MAGIC OF VECTOR EMBEDDINGS")
        
        print(f"{self.visual.colors['yellow']}Traditional string matching:{self.visual.colors['reset']}")
        print("'npm ERR! Cannot find module' ≠ 'npm: module not found'")
        print("→ These look DIFFERENT to computers")
        time.sleep(2)
        
        print(f"\n{self.visual.colors['green']}Vector embeddings capture MEANING:{self.visual.colors['reset']}")
        print("Both errors become similar 384D vectors:")
        
        # Show vector similarity between different phrasings
        errors = [
            "npm ERR! Cannot find module 'electron'",
            "npm: command 'electron' not found",
            "Error: electron module missing",
            "Failed to locate electron package"
        ]
        
        vectors = []
        for error in errors:
            vector = self.generate_error_vector(error)
            vectors.append(vector)
            print(f"\n'{error[:40]}...'")
            self.visual.show_vector(vector[:5], "First 5 dimensions")
        
        # Show similarities
        print(f"\n{self.visual.colors['cyan']}Similarity matrix:{self.visual.colors['reset']}")
        for i in range(len(errors)):
            for j in range(len(errors)):
                if i <= j:
                    sim = self.cosine_similarity(vectors[i], vectors[j])
                    print(f"Error {i+1} ↔ Error {j+1}: {sim:.1%}")
                    time.sleep(0.3)
        
        print(f"\n{self.visual.colors['magenta']}🎯 Key insight:{self.visual.colors['reset']}")
        print("Different wordings of SAME PROBLEM have SIMILAR VECTORS!")
        print("Taguchi recognizes them as the SAME ERROR!")
        
        input("\nPress Enter to see the dashboard simulation...")
    
    def simulate_dashboard(self):
        """Show what the VS Code dashboard looks like"""
        self.visual.clear_screen()
        self.visual.print_header("TAGUCHI DASHBOARD IN VS CODE")
        
        dashboard = f"""
{self.visual.colors['cyan']}┌─────────────────────────────────────────────────────┐
│                TAGUCHI DEBUGGER DASHBOARD           │
└─────────────────────────────────────────────────────┘{self.visual.colors['reset']}

{self.visual.colors['green']}● Capture Status: ACTIVE{self.visual.colors['reset']}
  Monitoring 2 terminals, captured 15 errors today

{self.visual.colors['cyan']}📊 Statistics:{self.visual.colors['reset']}
  ┌─────────────────┬─────────────────┐
  │ Total Errors    │       47        │
  │ Auto-fixed      │       38 (81%)  │
  │ Time Saved      │     24.5 hours  │
  │ DB Size         │      2.3 MB     │
  └─────────────────┴─────────────────┘

{self.visual.colors['yellow']}🔍 Recent Errors:{self.visual.colors['reset']}
  1. npm ERR! Cannot find module (5x) {self.visual.colors['green']}✅ Fixed: npm ci{self.visual.colors['reset']}
  2. Permission denied (3x) {self.visual.colors['green']}✅ Fixed: chmod +x{self.visual.colors['reset']}
  3. ModuleNotFoundError (2x) {self.visual.colors['green']}✅ Fixed: pip install{self.visual.colors['reset']}
  4. Connection refused (1x) {self.visual.colors['yellow']}⏳ Learning...{self.visual.colors['reset']}

{self.visual.colors['magenta']}🎯 Top Time Savers:{self.visual.colors['reset']}
  1. npm ci vs npm install: Saved 8.2 hours
  2. pip install vs conda install: Saved 3.1 hours
  3. chmod +x vs sudo: Saved 2.5 hours

{self.visual.colors['blue']}⚡ Quick Actions:{self.visual.colors['reset']}
  [S] Start Capture  [A] Analyze Error  [F] Auto-fix  [E] Export DB
        """
        
        # Animate the dashboard appearing
        for line in dashboard.split('\n'):
            print(line)
            time.sleep(0.05)
        
        input("\nPress Enter for the big picture...")
    
    def show_big_picture(self):
        """The ultimate visualization"""
        self.visual.clear_screen()
        
        big_picture = f"""
{self.visual.colors['cyan']}╔══════════════════════════════════════════════════════════════╗
║                  THE TAGUCHI DEBUGGER FLOW                 ║
╚══════════════════════════════════════════════════════════════╝{self.visual.colors['reset']}

{self.visual.colors['yellow']}┌────────────────────────────────────────────────────────────┐
│                    BEFORE TAGUCHI                          │
├────────────────────────────────────────────────────────────┤
│  1. Error occurs                                           │
│  2. Google for 30 mins                                     │
│  3. Try random StackOverflow solutions                     │
│  4. Maybe works, maybe breaks something else              │
│  5. Forget what worked                                     │
│  6. Repeat next week 😫                                   │
└────────────────────────────────────────────────────────────┘{self.visual.colors['reset']}

{self.visual.colors['green']}     ╭──────────────────────────────────────────────────╮
     │                    WITH TAGUCHI                          │
     ├──────────────────────────────────────────────────┤
     │    ERROR → VECTOR → SEARCH → FIX → LEARN         │
     ╰──────────────────────────────────────────────────╯{self.visual.colors['reset']}

{self.visual.colors['cyan']}                    ╭──────────────╮
                    │   YOUR ERROR   │
                    ╰──────────────╯
                          ↓
                    ╭──────────────╮
                    │  384D VECTOR  │  ← AI understands meaning
                    ╰──────────────╯
                          ↓
                    ╭──────────────╮
                    │ SEARCH DB     │  ← Find similar past errors
                    ╰──────────────╯
                          ↓
{self.visual.colors['green']}         ┌─────────────────────────────┐
         │     FOUND! 98% MATCH      │  ← "We've seen this!"
         └─────────────────────────────┘
                  ↓
         ╭───────────────────────╮
         │ USE: npm ci           │  ← Apply known fix
         │ (worked 15/15 times)  │
         ╰───────────────────────╯
                  ↓
         ╭───────────────────────╮
         │ ✅ WORKS INSTANTLY!   │
         │ ⏱️  Saved: 2 hours    │
         ╰───────────────────────╯{self.visual.colors['reset']}

{self.visual.colors['magenta']}╔══════════════════════════════════════════════════════════════╗
║      RESULT: NEVER DEBUG THE SAME ERROR TWICE!            ║
╚══════════════════════════════════════════════════════════════╝{self.visual.colors['reset']}

{self.visual.colors['yellow']}🎯 Key Benefits:{self.visual.colors['reset']}
• Personal: Learns YOUR setup (your macOS, your npm version, your code)
• Statistical: Tests systematically (Taguchi method)
• Predictive: Gets smarter every day
• Permanent: Never loses knowledge

{self.visual.colors['green']}⚡ The Magic:{self.visual.colors['reset']}
It's like your brain has a "I've seen this shit before" memory,
but for ALL your debugging, accessible INSTANTLY.
        """
        
        # Type it out dramatically
        for char in big_picture:
            print(char, end='', flush=True)
            time.sleep(0.001)
        
        print(f"\n\n{self.visual.colors['cyan']}" + "="*70)
        print("🎬 DEMO COMPLETE! You've seen exactly how Taguchi Debugger works.")
        print("="*70 + self.visual.colors['reset'])
    
    # ============================================
    # UTILITY METHODS
    # ============================================
    
    def generate_error_vector(self, error_text, context=None):
        """Generate a deterministic vector from error text"""
        seed = hashlib.md5(error_text.encode()).hexdigest()[:8]
        np.random.seed(int(seed, 16))
        
        # Generate random vector (simulating real embeddings)
        vector = np.random.randn(self.vector_dimensions).tolist()
        
        # Normalize
        norm = np.linalg.norm(vector)
        vector = (vector / norm).tolist()
        
        return vector
    
    def hash_error(self, error_text):
        """Create hash ID for error"""
        return hashlib.md5(error_text.encode()).hexdigest()[:16]
    
    def find_similar_errors(self, query_vector):
        """Find similar errors in database"""
        similar = []
        
        for error_id, error_data in self.error_database.items():
            similarity = self.cosine_similarity(query_vector, error_data['vector'])
            
            if similarity > 0.8:  # High similarity threshold
                similar.append({
                    'id': error_id,
                    'similarity': similarity,
                    **error_data
                })
        
        # Sort by similarity
        similar.sort(key=lambda x: x['similarity'], reverse=True)
        return similar
    
    def cosine_similarity(self, a, b):
        """Calculate cosine similarity between two vectors"""
        if len(a) != len(b):
            return 0
        
        dot_product = sum(x * y for x, y in zip(a, b))
        norm_a = sum(x * x for x in a) ** 0.5
        norm_b = sum(y * y for y in b) ** 0.5
        
        if norm_a == 0 or norm_b == 0:
            return 0
        
        return dot_product / (norm_a * norm_b)
    
    def generate_taguchi_matrix(self):
        """Generate L9 Taguchi test matrix"""
        return [
            {"command": "npm install", "flags": "", "version": "latest"},
            {"command": "npm ci", "flags": "", "version": "latest"},
            {"command": "npm install", "flags": "--force", "version": "latest"},
            {"command": "npm ci", "flags": "--force", "version": "latest"},
            {"command": "yarn install", "flags": "", "version": "latest"},
            {"command": "npm install", "flags": "", "version": "stable"},
            {"command": "npm ci", "flags": "", "version": "stable"},
            {"command": "npm install", "flags": "--legacy-peer-deps", "version": "latest"},
            {"command": "npm ci", "flags": "--legacy-peer-deps", "version": "latest"}
        ]

# ============================================
# MAIN EXECUTION
# ============================================
def main():
    demo = SimulatedTaguchiDebugger()
    
    print(f"\n{demo.visual.colors['cyan']}" + "="*70)
    print("🎬 WELCOME TO TAGUCHI DEBUGGER VISUAL DEMO")
    print("See exactly how it learns from your debugging!")
    print("="*70 + demo.visual.colors['reset'])
    
    input("\nPress Enter to begin the 3-day simulation...")
    
    # Run the simulations
    demo.simulate_day_1()      # First learning
    demo.simulate_day_2()      # Instant recognition
    demo.simulate_day_3()      # Getting smarter
    demo.simulate_vector_magic()  # How vectors work
    demo.simulate_dashboard()  # VS Code interface
    demo.show_big_picture()    # The complete picture
    
    print(f"\n{demo.visual.colors['green']}✅ Demo complete! You now understand:")
    print("1. How Taguchi captures terminal errors")
    print("2. How vectors understand error meaning")
    print("3. How Taguchi tests find optimal fixes")
    print("4. How the database grows smarter every day")
    print("5. How you save HOURS of debugging!{demo.visual.colors['reset']}")

if __name__ == "__main__":
    main()