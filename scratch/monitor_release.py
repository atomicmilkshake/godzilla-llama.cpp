import json
import subprocess
import sys
from rich.console import Console
from rich.table import Table
from rich.panel import Panel

def main():
    import sys
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        
    run_id = "28712067397"
    repo = "atomicmilkshake/godzilla-llama.cpp"
    console = Console()
    
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
            sys.exit(0)
            
        data = json.loads(result.stdout)
    except Exception as e:
        console.print(banner)
        console.print(f"[bold red]Exception checking build:[/bold red] {e}")
        sys.exit(0)
        
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
        
        if j_status == "in_progress":
            in_progress_count += 1
            all_success = False
            status_str = "[bold blink cyan]⌛ RUNNING[/bold blink cyan]"
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
                result_str = "[bold green]✅ SUCCESS[/bold green]"
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
        sys.exit(2)
    else:
        console.print("\n[bold cyan]🛸 System polling active. Stand by...[/bold cyan]")
        sys.exit(0)

if __name__ == "__main__":
    main()
