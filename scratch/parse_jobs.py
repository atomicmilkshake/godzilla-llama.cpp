import json

def main():
    try:
        with open("scratch/jobs.json", "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"Error loading jobs: {e}")
        return
        
    for job in data.get("jobs", []):
        name = job.get("name", "Unknown")
        status = job.get("status", "")
        conclusion = job.get("conclusion", "")
        db_id = job.get("databaseId", "")
        
        if conclusion == "failure":
            print(f"[FAIL] Job Failed: {name} (ID: {db_id})")
            for step in job.get("steps", []):
                s_name = step.get("name", "")
                s_status = step.get("status", "")
                s_conclusion = step.get("conclusion", "")
                if s_conclusion == "failure":
                    print(f"  [-] Failed Step: {s_name}")

if __name__ == "__main__":
    main()
