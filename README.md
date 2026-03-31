# Gemini CLI: Prompt-Driven Sub-Agent Orchestrator

This project is a proof-of-concept demonstrating a sub-agent orchestration system built entirely within the Gemini CLI using its native features. It uses a filesystem-as-state architecture, managed by a suite of prompt-driven custom commands, to orchestrate complex, asynchronous tasks performed by specialized AI agents.

## Core Concepts

1.  **Filesystem-as-State**: The entire state of the system (task queue, plans, logs) is stored in structured directories on the filesystem, making it transparent and easily debuggable. There are no external databases or process managers.

2.  **Prompt-Driven Commands**: The logic for the orchestrator is not written in a traditional programming language. Instead, it's defined in a series of prompts within `.toml` files, which create new, project-specific commands in the Gemini CLI (e.g., `/agents:start`).

3.  **Asynchronous Agents**: Sub-agents are launched as background processes. The orchestrator tracks them via their Process ID (PID) and reconciles their status by checking for a sentinel `.done` file upon their completion.

## Architecture

-   **Orchestrator**: A set of custom Gemini CLI commands (`/agents:*`) that manage the entire lifecycle of agent tasks, from creation to completion.
-   **Sub-Agents**: Specialized Gemini CLI extensions, each with a unique persona and a constrained set of capabilities (e.g., `tester-agent`, `verifier-agent`, `coder-agent`, `pr-agent`).
-   **Device Pool Manager**: A filesystem-based device locking system (`bin/device-pool.sh`) that manages parallel test execution across multiple mobile devices, preventing task conflicts.
-   **Pipeline Orchestrator**: An end-to-end automation script (`bin/run-pipeline.sh`) that chains all stages from test execution to PR creation.

## Directory Structure

The entire system is contained within the `.gemini/` directory. This image shows the structure of the `agents` and `commands` directories that power the system.

<img src="media/project-folder-structure.png" alt="Project Folder Structure" width="500"/>

-   `agents/`: Contains the definitions for the sub-agents and the workspace where they operate.
    -   `tasks/`: Contains the JSON state files for each task and `.done` sentinel files.
    -   `plans/`: Holds Markdown files for agents' long-term planning.
    -   `logs/`: Stores the output logs, `uitest_results.json`, `device_verification.json`, `fix_report.json` from each agent.
    -   `workspace/`: A dedicated directory where agents can create and modify files.
    -   `state/`: Device pool state (`device_pool.json`) and per-device lock files (`locks/`).
-   `commands/`: Contains the `.toml` files that define the custom `/agents` commands.
-   `extensions/`: Agent persona definitions (`tester-agent`, `verifier-agent`, `coder-agent`, `pr-agent`, etc.).
-   `rules/`: Platform-specific test conventions (`android-uitest-conventions.md`, `ios-uitest-conventions.md`).

## Commands

### Core Commands
-   `/agents:start <agent_name> "<prompt>"`: Queues a new task by creating a JSON file in the `tasks` directory.
-   `/agents:run [task_id]`: Executes the oldest pending task (or a specific task) by launching the corresponding agent as a background process.
-   `/agents:run-all [agent_type] [--max-parallel N]`: Batch-executes all pending tasks with device pool limits. Automatically respects available device count for device-bound agents.
-   `/agents:status [task_id]`: Reports the status of all tasks. It first reconciles any completed tasks by checking for `.done` files.
-   `/agents:type`: Lists the available agent extensions.

### UITest Pipeline Commands
-   `/agents:pipeline [--skip-verify] [--skip-pr] [--suite <name>]`: Runs the full end-to-end UITest pipeline (discover → test → aggregate → verify → fix → PR).
-   `/agents:test-planing`: Scans workspace for CriticalRT test suite and creates per-class tester-agent tasks.
-   `/agents:verify <uitest_results.json_path>`: Creates a verifier-agent task to verify failed tests on a real device.
-   `/agents:fix <device_verification.json_path>`: Creates parallel coder-agent tasks (one per failing class) and launches them.
-   `/agents:pr [project_path]`: Creates a pr-agent task to collect fix reports and open a GitHub PR.

### Utility Scripts
-   `bin/device-pool.sh`: Device pool manager — `discover`, `acquire`, `release`, `status`, `cleanup`, `count`.
-   `bin/run-pipeline.sh`: Shell-based end-to-end pipeline orchestrator.
-   `bin/aggregate-test-results.py`: Merges multiple `uitest_results.json` files into one aggregated file.
-   `bin/run-agent-with-retry.sh`: Agent executor with model fallback and device pool integration.
-   `bin/reconcile-tasks.sh`: Detects failed tasks, resets to pending, cleans up stale device locks.
-   `bin/parse-android-test-results.py`: Parses JUnit XML test results into structured JSON.

## Example Workflows

### Quick Start: Full Pipeline (One Command)

```bash
# Run the entire UITest pipeline end-to-end
bin/run-pipeline.sh

# Or via Gemini CLI command
gemini /agents:pipeline

# With options
bin/run-pipeline.sh --skip-verify --suite SanitySuite
```

### Step-by-Step: Manual Workflow

1.  **Discover Devices**:
    ```bash
    bin/device-pool.sh discover
    # Output: Discovered: Android 2 (2 idle), iOS 0 (0 idle)
    ```

2.  **Create Test Tasks**:
    ```bash
    gemini /agents:test-planing
    ```

3.  **Run All Tests (device-limited parallelism)**:
    ```bash
    gemini /agents:run-all tester-agent
    ```

4.  **Aggregate Results**:
    ```bash
    python3 bin/aggregate-test-results.py
    # Output: Total: 25, Passed: 22, Failed: 3
    ```

5.  **Verify Failures on Real Device**:
    ```bash
    gemini /agents:verify .gemini/agents/logs/aggregated_uitest_results.json
    gemini /agents:run
    ```

6.  **Fix Failures**:
    ```bash
    gemini /agents:fix .gemini/agents/logs/task_xxx_device_verification.json
    ```

7.  **Create PR**:
    ```bash
    gemini /agents:pr
    gemini /agents:run
    ```

### Legacy: Single Agent Task

```bash
gemini /agents:start coder-agent "Fix failing test in GlobalHomeAndroidViewTest"
gemini /agents:run
gemini /agents:status
```

## Device Pool Manager

The device pool manager (`bin/device-pool.sh`) prevents multiple tasks from using the same mobile device simultaneously.

-   **Filesystem-based locking**: Uses atomic `mkdir` for lock acquisition, consistent with the project's filesystem-as-state architecture.
-   **Automatic integration**: `run-agent-with-retry.sh` automatically acquires/releases devices for `tester-agent` and `verifier-agent`.
-   **Stale lock cleanup**: Dead PIDs and TTL-expired locks (30 min) are automatically cleaned up during reconciliation.

```bash
bin/device-pool.sh discover   # Scan connected devices
bin/device-pool.sh status     # Show device pool state
bin/device-pool.sh cleanup    # Remove stale locks
```

### Final Output

The `coder-agent` successfully creates a web application in the `.gemini/agents/workspace/github-repo-viewer` directory. Here is a screenshot of the final running application:

![GitHub Repo Viewer Screenshot](media/github-repo-viewer.png)

---

## Further Reading

-   **Blog Post**: [How I Turned Gemini CLI into a Multi-Agent System with Just Prompts](https://aipositive.substack.com/p/how-i-turned-gemini-cli-into-a-multi)
-   **Demo Video**: [See it in Action](https://aipositive.substack.com/i/169284045/see-it-in-action)

---

## Disclaimer

This project is a proof-of-concept experiment.

-   **Inspiration**: The core architecture is inspired by Anthropic's documentation on [Building a Sub-Agent with Claude](https://docs.anthropic.com/en/docs/claude-code/sub-agents).
-   **Roadmap**: A more robust and official agentic feature is on the [Gemini CLI roadmap](https://github.com/google-gemini/gemini-cli/issues/4168).
-   **Security**: This implementation is **not secure for production use**. It relies on the `-y` (`--yolo`) flag, which bypasses important security checks. For any real-world application, you should enable features like checkpointing and sandboxing. For more information, please refer to the [official Gemini CLI documentation](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/commands.md).