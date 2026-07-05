# -*- coding: utf-8 -*-
import json
import subprocess
import sys
import re
import os
import time
import datetime
from rich.console import Console
from rich.table import Table
from rich.panel import Panel

def parse_utc_timestamp(ts_str):
    if not ts_str or ts_str.startswith("0001-"):
        return None
    clean_str = ts_str.replace("Z", "+00:00")
    try:
        return datetime.datetime.fromisoformat(clean_str)
    except Exception:
        try:
            return datetime.datetime.strptime(clean_str.split("+")[0], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
        except Exception:
            return None

def format_duration(td):
    if not td:
        return ""
    total_seconds = int(td.total_seconds())
    if total_seconds < 0:
        total_seconds = 0
    hours = total_seconds // 3600
    minutes = (total_seconds % 3600) // 60
    seconds = total_seconds % 60
    
    if hours > 0:
        return f"{hours}h {minutes}m"
    elif minutes > 0:
        return f"{minutes}m {seconds}s"
    else:
        return f"{seconds}s"

def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        
    console = Console()
    
    # Check for once/loop flags
    once = False
    if "--once" in sys.argv:
        once = True
        sys.argv.remove("--once")
    if "-o" in sys.argv:
        once = True
        sys.argv.remove("-o")
        
    # Default repo
    repo = "atomicmilkshake/godzilla-llama.cpp"
    try:
        rem = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True, shell=True)
        if rem.returncode == 0:
            match = re.search(r"github\.com[:/]([^/]+/[^/]+)", rem.stdout.strip())
            if match:
                repo = match.group(1).replace(".git", "")
    except Exception:
        pass
        
    run_id = None
    if len(sys.argv) > 1:
        run_id = sys.argv[1]
    else:
        try:
            run_list = subprocess.run(
                ["gh", "run", "list", "--repo", repo, "--workflow", "release.yml", "--limit", "1", "--json", "databaseId"],
                capture_output=True,
                text=True,
                shell=True
            )
            if run_list.returncode == 0:
                runs = json.loads(run_list.stdout)
                if runs:
                    run_id = str(runs[0]["databaseId"])
        except Exception:
            pass
            
    if not run_id:
        # Fallback to current active run ID
        run_id = "28717696903"
    
    # ASCII Art Banner (Matrix / Hackers style)
    banner = r"""
[bold green]
  ________  ________  ________  ________  ___  ___       ___       ________     
 |\   ____\|\   __  \|\   ___ \|\_____  \|\  \|\  \     |\  \     |\   __  \    
 \ \  \___| \ \  \\\  \ \  \_|\ \|____  /\ \  \ \  \    \ \  \    \ \  \\\  \   
  \ \  \  __ \ \  \\\  \ \  \ \\ \   /  /  \ \  \ \  \    \ \  \    \ \  __  \  
   \ \  \|\  \ \  \\\  \ \  \_\\ \  /  /_   \ \  \ \  \____\ \  \____\ \  \ \  \ 
    \ \_______\ \_______\ \_______\/_______\ \__\ \_______\ \_______\ \__\ \__\
     \|_______|\|_______|\|_______|\|_______|\|__|\|_______|\|_______|\|__|\|__|
[/bold green]
[bold cyan]                       ::: COMPILATION SYSTEM ACTIVE :::[/bold cyan]
"""

    while True:
        if not once:
            os.system("cls" if os.name == "nt" else "clear")
            
        try:
            result = subprocess.run(
                ["gh", "run", "view", run_id, "--repo", repo, "--json", "status,conclusion,jobs"],
                capture_output=True,
                text=True,
                shell=True
            )
            if result.returncode != 0:
                console.print(banner)
                console.print(f"[bold red]Error calling gh CLI:[/bold red] {result.stderr.strip()}")
                sys.exit(1)
                
            data = json.loads(result.stdout)
        except Exception as e:
            console.print(banner)
            console.print(f"[bold red]Exception checking build:[/bold red] {e}")
            sys.exit(1)
            
        status = data.get("status", "unknown")
        conclusion = data.get("conclusion", "none") or "none"
        jobs = data.get("jobs", [])
        
        # Sort jobs by name
        jobs.sort(key=lambda j: j.get("name", ""))
        
        any_failed = False
        all_success = True
        in_progress_count = 0
        completed_count = 0
        queued_count = 0
        
        # Create tactical table
        table = Table(
            title=f"📡 SYSTEM ARCHITECTURE MATRIX | BUILD TARGET: v0.3.3",
            title_style="bold cyan",
            show_header=True,
            header_style="bold magenta",
            border_style="cyan"
        )
        table.add_column("🖥️ COMPILER TARGET / PLATFORM", style="dim green", width=38)
        table.add_column("⚡ STATUS", justify="center")
        table.add_column("🎯 RESULT", justify="center")
        table.add_column("🔧 ID", justify="right", style="dim cyan")
        
        for job in jobs:
            name = job.get("name", "Unknown")
            j_status = job.get("status", "unknown")
            j_conclusion = job.get("conclusion", "none") or "none"
            job_id = str(job.get("id", ""))
            
            started_at = parse_utc_timestamp(job.get("startedAt"))
            completed_at = parse_utc_timestamp(job.get("completedAt"))
            
            duration_str = ""
            if started_at:
                if j_status == "completed" and completed_at:
                    duration_str = format_duration(completed_at - started_at)
                elif j_status == "in_progress":
                    now_utc = datetime.datetime.now(datetime.timezone.utc)
                    duration_str = format_duration(now_utc - started_at)
            
            if j_status == "in_progress":
                in_progress_count += 1
                all_success = False
                status_str = "[bold blink cyan]⌛ RUNNING[/bold blink cyan]"
                if duration_str:
                    result_str = f"[cyan]compiling... ({duration_str})[/cyan]"
                else:
                    result_str = "[cyan]compiling...[/cyan]"
            elif j_status == "queued":
                queued_count += 1
                all_success = False
                status_str = "[bold yellow]📋 QUEUED[/bold yellow]"
                result_str = "[yellow]waiting[/yellow]"
            elif j_status == "completed":
                completed_count += 1
                status_str = "[bold green]🏁 DONE[/bold green]"
                if j_conclusion == "success":
                    if duration_str:
                        result_str = f"[bold green]✅ SUCCESS ({duration_str})[/bold green]"
                    else:
                        result_str = "[bold green]✅ SUCCESS[/bold green]"
                else:
                    if duration_str:
                        result_str = f"[bold red]❌ FAILED ({duration_str})[/bold red]"
                    else:
                        result_str = "[bold red]❌ FAILED[/bold red]"
                    any_failed = True
                    all_success = False
            else:
                status_str = f"[bold white]{j_status}[/bold white]"
                result_str = f"[white]{j_conclusion}[/white]"
                all_success = False
                
            table.add_row(name, status_str, result_str, job_id)
            
        total_jobs = len(jobs)
        
        # Dashboard metrics panel
        dashboard_text = (
            f"[bold green]Tactical Uplink:[/bold green] ESTABLISHED\n"
            f"[bold green]System Run State:[/bold green] [bold cyan]{status.upper()}[/bold cyan]\n"
            f"[bold green]Final Verdict:[/bold green] [bold magenta]{conclusion.upper()}[/bold magenta]\n"
            f"[bold green]Compiler Load:[/bold green] [green]{completed_count}[/green]/[cyan]{total_jobs}[/cyan] completed | "
            f"[cyan]{in_progress_count}[/cyan] compiling | [yellow]{queued_count}[/yellow] in queue"
        )
        
        # Print system output
        console.print(banner)
        console.print(Panel(dashboard_text, title="📟 TACTICAL DASHBOARD", border_style="bold green"))
        if total_jobs > 0:
            console.print(table)
        else:
            console.print(Panel("[bold yellow]⚠️ INITIALIZING TARGET MATRIX... NO ACTIVE JOBS DETECTED YET[/bold yellow]", border_style="yellow"))
            
        if any_failed:
            console.print("\n[bold red]💥 SYSTEM ERROR: Critical compilation failures detected in the grid![/bold red]")
            sys.exit(1)
        elif all_success and status == "completed":
            console.print("\n[bold green]👑 MISSION ACCOMPLISHED: All target platforms compiled successfully![/bold green]")
            sys.exit(0)
            
        if once:
            break
            
        console.print("\n[bold cyan]🛸 System polling active. Auto-refreshing in 15 seconds... [Ctrl+C to Exit][/bold cyan]")
        try:
            time.sleep(15)
        except KeyboardInterrupt:
            console.print("\n[bold yellow]Monitoring interrupted by user. Exiting.[/bold yellow]")
            sys.exit(0)

if __name__ == "__main__":
    main()
