

# RUFKIS-08: Task Tracker with Multi-Step Progress

**Bounded Context:** `project-management`  
**Tech Stack:** Go, PostgreSQL, NATS, gRPC, OpenTelemetry, CloudEvents  
**Architecture:** Hexagonal (Ports & Adapters)

---

## 1. User Stories

### PM-01: Create Tasks with Ordered and Weighted Steps

**As a** project manager  
**I want** to create tasks with ordered and weighted steps  
**So that** I can decompose work into measurable units with proper prioritization

```gherkin
Given I am authenticated in the project-management context
When I create a task with title "Deploy microservices"
And I add steps [
  {"name":"Build images","order":1,"weight":0.5},
  {"name":"Update configs","order":2,"weight":0.3},
  {"name":"Rollout canary","order":3,"weight":0.2}
]
Then the task is created with status TODO
And the steps are persisted with the specified order and weights
And the total weight of all steps sums to 1.0

Given a task "Deploy microservices" exists with 3 steps
When I attempt to create a step with order 1 (duplicate)
Then I receive a validation error "Step order must be unique within a task"

Given a task exists with steps
When I attempt to set a step weight to -0.1
Then I receive a validation error "Step weight must be a positive number"
```

### PM-02: Task Status Transitions with Enforced Rules

**As a** team member  
**I want** to transition task status through allowed states (TODO, IN_PROGRESS, BLOCKED, DONE) with enforced rules  
**So that** the workflow is predictable and gated properly

```gherkin
Given a task "Deploy microservices" has status TODO
When I transition the task status to IN_PROGRESS
Then the task status becomes IN_PROGRESS
And an event project-management.TaskStatusChanged is emitted with oldStatus=TODO, newStatus=IN_PROGRESS

Given a task "Deploy microservices" has status TODO
When I attempt to transition the task status directly to DONE
Then I receive a validation error "Cannot transition from TODO to DONE"
And the task status remains TODO

Given a task "Deploy microservices" has status IN_PROGRESS
And the task has 3 steps where only 1 step has status DONE
When I attempt to transition the task status to DONE
Then I receive a validation error "Cannot mark DONE until all steps are completed"
And the task status remains IN_PROGRESS

Given a task "Deploy microservices" has status BLOCKED
When I transition the task status to IN_PROGRESS
Then the task status becomes IN_PROGRESS

Given a task "Deploy microservices" has status BLOCKED
When I attempt to transition the task status to TODO
Then I receive a validation error "Cannot transition from BLOCKED to TODO"
```

### PM-03: Progress Percentage Calculation

**As a** project manager  
**I want** progress percentage calculated automatically based on weighted step completion  
**So that** I have an accurate real-time view of completion

```gherkin
Given a task "Deploy microservices" with steps: [
  {name:"Build images",weight:0.5,status:DONE},
  {name:"Update configs",weight:0.3,status:IN_PROGRESS},
  {name:"Rollout canary",weight:0.2,status:TODO}
]
When I query the task progress
Then the progress percentage is 50%
(calculated as: 0.5*100 + 0.3*0 + 0.2*0 = 50%)

Given a task with steps weighted evenly at 0.25 each, and 2 of 4 steps are DONE
When I query the task progress
Then the progress percentage is 50%

Given a task with zero steps
When I query the task progress
Then the progress percentage is 0%

Given a task where all steps have status DONE
When I query the task progress
Then the progress percentage is 100%
```

### PM-04: Step Status Lifecycle

**As a** team member  
**I want** to update step status independently through the same lifecycle  
**So that** I can track granular progress at the step level

```gherkin
Given a step "Build images" belonging to task "Deploy microservices" has status TODO
When I transition the step status to IN_PROGRESS
Then the step status becomes IN_PROGRESS
And the parent task progress is recalculated
And an event project-management.StepStatusChanged is emitted

Given a step "Build images" has status IN_PROGRESS
When I transition the step status to DONE
Then the step status becomes DONE
And the parent task progress is recalculated

Given a step "Build images" has status DONE
When I attempt to transition the step status back to TODO
Then I receive a validation error "Cannot transition step from DONE to TODO"
```

### PM-05: Task Dependencies

**As a** project manager  
**I want** task dependency relationships to prevent starting a task until all its dependencies are done  
**So that** the workflow order is enforced

```gherkin
Given tasks A (status DONE), B (status DONE), and C (status TODO)
When I add tasks A and B as dependencies of task C
Then the dependency relationships are created

Given task C has dependencies [A,B] where A is DONE and B is TODO
When I attempt to transition task C from TODO to IN_PROGRESS
Then I receive a validation error "Cannot start task C: dependency task B is not DONE"
And the task status remains TODO

Given task C has dependencies [A,B] where A is DONE and B is DONE
When I transition task C from TODO to IN_PROGRESS
Then the task status becomes IN_PROGRESS

Given task C has a dependency on task A
When I attempt to add a dependency from task A to task C (creating a cycle)
Then I receive a validation error "Cannot add dependency: would create a cycle"

Given task A is a dependency of task B
When I attempt to delete task A
Then I receive a validation error "Cannot delete task A: it is a dependency of task B"
```

### PM-06: Time Tracking on Steps

**As a** team member  
**I want** to track estimated vs actual time on each step with start/stop logging  
**So that** we can measure effort accuracy

```gherkin
Given a step "Build images" with estimatedTimeMinutes=120
When I start work on the step
Then the step startTime is recorded as the current timestamp
And the step status transitions to IN_PROGRESS automatically

Given the step "Build images" is IN_PROGRESS with a recorded startTime
When I stop work on the step
Then the step accumulatedTime is increased by (stopTime - startTime)
And the step startTime is cleared

Given the step "Build images" has accumulatedTime=60 and estimatedTimeMinutes=120
When I query the step time report
Then the step shows estimated=120, actual=60, remaining=60

Given the step "Build images" has accumulatedTime=180 and estimatedTimeMinutes=120
When I query the step time report
Then the step shows estimated=120, actual=180, overage=60

Given a step is in DONE status
When I attempt to start the timer on the step
Then I receive a validation error "Cannot start time tracking on a completed step"
```

### PM-07: Assignee Management

**As a** project manager  
**I want** to assign and reassign tasks and steps to team members with a full change history  
**So that** accountability and workload distribution are clear

```gherkin
Given a task "Deploy microservices" with no assignee
When I assign the task to user "alice@example.com"
Then the task assignee is "alice@example.com"
And an event project-management.TaskAssigneeChanged is emitted with oldAssignee=null, newAssignee="alice@example.com", changedBy=currentUser

Given the task is assigned to "alice@example.com"
When I reassign the task to "bob@example.com"
Then the task assignee becomes "bob@example.com"
And the assignee change is appended to the history log

Given a step "Build images" belonging to task "Deploy microservices"
When I assign the step to "carol@example.com"
Then the step assignee is "carol@example.com"
And the step assignee is independent of the parent task assignee

Given I query the assignee history for task "Deploy microservices"
When the task has had 3 assignee changes
Then the history returns all 3 entries with timestamp, oldAssignee, newAssignee, changedBy
```

### PM-08: Real-Time Progress Events via NATS/CloudEvents

**As a** downstream system  
**I want** to consume progress update events via NATS/CloudEvents  
**So that** I can react to progress changes in real time

```gherkin
Given a task "Deploy microservices" has progressPercentage=50%
When a step status changes causing progress to become 75%
Then a CloudEvent is published on NATS subject "project-management.progress.updated"
And the event payload contains: {taskId, projectId, progressPercentage:75, oldPercentage:50, changedStepId, timestamp}
And the event includes CloudEvent attributes: specversion, source, type="project-management.ProgressUpdated", id, time

Given a task has progressPercentage=100%
When an observer service subscribes to "project-management.progress.updated"
Then the observer receives the event within 100ms (as measured by OpenTelemetry trace)

Given a progress update event is published across a multi-cloud deployment
When the event crosses cloud region boundaries
Then the event payload excludes any data subject to GDPR/regional data residency restrictions (PII fields are stripped)
```

### PM-09: Nested Sub-Tasks with Recursive Progress

**As a** team member  
**I want** nested sub-tasks with recursive progress calculation  
**So that** deeply hierarchical work structures are accurately tracked

```gherkin
Given a parent task "Release v2.0" with sub-tasks ["Backend","Frontend"] where:
  - "Backend" has steps [{name:"API",weight:0.5,status:DONE},{name:"DB",weight:0.5,status:DONE}] (100%)
  - "Frontend" has steps [{name:"UI",weight:1.0,status:IN_PROGRESS}] (0%)
When I query the parent task "Release v2.0" progress
Then the progress percentage is 50% (weighted average of sub-tasks at equal weight)

Given a sub-task "Backend" has its own steps
When the sub-task "Backend" reaches 100%
Then the parent task "Release v2.0" progress is recalculated recursively

Given a depth-3 hierarchy: Epic > Feature > Story > Step
When any leaf Step changes status
Then the entire ancestor chain recalculates progress up to the root Epic
```

---

## 2. Domain Events (14 Total)

| ID | Event Name | Owner | Consumers | Payload Sketch |
|---|---|---|---|---|
| PM-EVT-01 | `project-management.TaskCreated` | project-management | billing, notifications, analytics | `{taskId, projectId, title, steps[], createdAt}` |
| PM-EVT-02 | `project-management.StepAdded` | project-management | notifications | `{taskId, stepId, stepName, weight, order}` |
| PM-EVT-03 | `project-management.TaskStatusChanged` | project-management | analytics, dashboards | `{taskId, oldStatus, newStatus, changedBy, timestamp}` |
| PM-EVT-04 | `project-management.ProgressUpdated` | project-management | **dashboards, notifications, analytics** | `{taskId, projectId, progressPercentage, oldPercentage, changedStepId, timestamp}` |
| PM-EVT-05 | `project-management.StepStatusChanged` | project-management | task (triggers recalculation) | `{taskId, stepId, oldStatus, newStatus}` |
| PM-EVT-06 | `project-management.DependencyAdded` | project-management | analytics | `{taskId, dependsOnTaskId}` |
| PM-EVT-07 | `project-management.TaskBlocked` | project-management | notifications | `{taskId, blockedByTaskIds[], reason}` |
| PM-EVT-08 | `project-management.StepTimerStarted` | project-management | billing, timesheets | `{taskId, stepId, userId, startTime}` |
| PM-EVT-09 | `project-management.StepTimerStopped` | project-management | billing, timesheets | `{taskId, stepId, userId, accumulatedDeltaMinutes, totalAccumulatedMinutes}` |
| PM-EVT-10 | `project-management.TaskAssigneeChanged` | project-management | notifications, workload-service | `{taskId, oldAssignee, newAssignee, changedBy, timestamp}` |
| PM-EVT-11 | `project-management.StepAssigneeChanged` | project-management | notifications | `{taskId, stepId, oldAssignee, newAssignee}` |
| PM-EVT-12 | `project-management.ProgressUpdated` (CloudEvent) | project-management | **external consumers** | Wraps PM-EVT-04 in CloudEvents envelope; PII stripped for cross-region |
| PM-EVT-13 | `project-management.SubTaskCreated` | project-management | parent-task (hierarchy rebuild) | `{parentTaskId, childTaskId}` |
| PM-EVT-14 | `project-management.ProgressUpdated` (recursive) | project-management | **ancestor tasks** | Recursively emitted at each hierarchy level |

### CloudEvents Specification

Every event published to NATS MUST conform to the CloudEvents 1.0 specification:

```json
{
  "specversion": "1.0",
  "id": "uuid-v4",
  "source": "/project-management/tasks",
  "type": "project-management.ProgressUpdated",
  "datacontenttype": "application/json",
  "time": "2025-01-15T10:30:00Z",
  "subject": "task-12345",
  "data": {
    "taskId": "task-12345",
    "progressPercentage": 75,
    "oldPercentage": 50,
    "changedStepId": "step-678",
    "timestamp": "2025-01-15T10:30:00Z"
  }
}
```

### Multi-Cloud / Data Residency

Events crossing regional boundaries MUST strip PII from the payload. The `data` field MUST NOT contain:
- User email addresses
- User names (use opaque user IDs only)
- Any free-text comments or descriptions
- IP addresses or location data

---

## 3. Domain Entities & Value Objects

### Entity: Task

| Field | Type | Description |
|---|---|---|
| `TaskID` | `UUID` | Primary identifier |
| `ProjectID` | `UUID` | Parent project |
| `Title` | `string` | Task title (max 200 chars) |
| `Description` | `string` | Optional (max 2000 chars) |
| `Status` | `TaskStatus` | Current status (enum) |
| `Steps` | `[]Step` | Ordered steps with weights |
| `ParentTaskID` | `*UUID` | For sub-tasks, nil if root |
| `Dependencies` | `[]UUID` | Task IDs this depends on |
| `Assignee` | `*string` | Current assignee (user ID) |
| `ProgressPercentage` | `float64` | Cached computed value (0-100) |
| `CreatedAt` | `timestamp` | |
| `UpdatedAt` | `timestamp` | |
| `Version` | `int32` | Optimistic concurrency |

### Value Object: TaskStatus

```go
type TaskStatus string

const (
    TaskStatusTODO       TaskStatus = "TODO"
    TaskStatusInProgress TaskStatus = "IN_PROGRESS"
    TaskStatusBlocked    TaskStatus = "BLOCKED"
    TaskStatusDone       TaskStatus = "DONE"
)
```

**Allowed Transitions:**
```
TODO       -> IN_PROGRESS
IN_PROGRESS -> BLOCKED, DONE
BLOCKED    -> IN_PROGRESS
DONE       -> (terminal — no transitions out)
```

### Entity: Step

| Field | Type | Description |
|---|---|---|
| `StepID` | `UUID` | Primary identifier |
| `TaskID` | `UUID` | Parent task |
| `Name` | `string` | Step name (max 100 chars) |
| `Order` | `int32` | Display/execution order (1-based) |
| `Weight` | `float64` | Contribution to parent progress (0.0-1.0) |
| `Status` | `TaskStatus` | Same status enum |
| `EstimatedTimeMinutes` | `int32` | Planned effort |
| `AccumulatedTimeMinutes` | `int32` | Total tracked time |
| `TimerStartTime` | `*timestamp` | Current timer start, nil if stopped |
| `Assignee` | `*string` | Step-level assignee (overrides task) |
| `CreatedAt` | `timestamp` | |
| `UpdatedAt` | `timestamp` | |

### Value Object: AssigneeChange

| Field | Type | Description |
|---|---|---|
| `TaskID` | `UUID` | |
| `OldAssignee` | `*string` | |
| `NewAssignee` | `string` | |
| `ChangedBy` | `string` | User who made the change |
| `ChangedAt` | `timestamp` | |

### Value Object: DependencyGraph

Managed as a DAG adjacency list with cycle detection.

---

## 4. Business Rules & Validation Constraints

### Task Creation
- Title is required: min 1 char, max 200 chars
- At least one step must be provided OR flag `isPlaceholder=true`
- Step weights must sum to 1.0 (tolerance: ±0.001 for floating point)
- Step orders must be unique within a task (1-based, sequential allowed but not enforced — gaps are okay)
- Step names must be unique within a task

### Status Transitions
- DONE is a terminal state: no transitions out
- Task cannot transition to IN_PROGRESS if any dependency is not DONE
- Task cannot transition to DONE unless all steps have status DONE
- Steps follow the same transition rules as tasks

### Dependencies
- No self-dependency (task cannot depend on itself)
- No cyclic dependencies (DAG must be acyclic — DFS cycle detection)
- Deleting a task that is a dependency of another task is forbidden
- Maximum dependency depth: 20 (configurable)

### Time Tracking
- Only one active timer per step at a time
- Cannot start timer on a DONE step
- Estimated time is immutable after the step becomes IN_PROGRESS
- Timer sessions are idempotent: starting when already started is a no-op

### Assignee
- Task assignee is optional
- Step assignee is optional; defaults to task assignee if not set
- Step assignee changes do not cascade to parent task
- Assignee history is append-only, never mutated

### Progress Calculation
- `progress = sum(step.weight * step.progress) for each step in task`
- Step progress is 100% if DONE, 0% otherwise
- Sub-task progress: recursively calculated; `progressPercentage` of sub-task is used as its "completion ratio"
- Cached value is invalidated on any step/sub-task status change, recalculated with eventual consistency (max 500ms staleness in cache)

---

## 5. Error Scenarios

| Error Code | HTTP Code | gRPC Code | Description |
|---|---|---|---|
| `TASK_NOT_FOUND` | 404 | NOT_FOUND | Task ID does not exist |
| `STEP_NOT_FOUND` | 404 | NOT_FOUND | Step ID does not exist |
| `INVALID_STATUS_TRANSITION` | 400 | FAILED_PRECONDITION | Transition not in allowed matrix |
| `DEPENDENCIES_NOT_MET` | 400 | FAILED_PRECONDITION | Cannot start: deps not DONE |
| `STEPS_NOT_COMPLETE` | 400 | FAILED_PRECONDITION | Cannot mark DONE: steps incomplete |
| `CYCLE_DETECTED` | 400 | FAILED_PRECONDITION | Adding dependency creates cycle |
| `SELF_DEPENDENCY` | 400 | INVALID_ARGUMENT | Task cannot depend on itself |
| `CANNOT_DELETE_DEPENDENCY` | 409 | FAILED_PRECONDITION | Task is a dependency of another task |
| `DUPLICATE_STEP_ORDER` | 400 | INVALID_ARGUMENT | Step order already exists in task |
| `DUPLICATE_STEP_NAME` | 400 | INVALID_ARGUMENT | Step name already exists in task |
| `WEIGHT_SUM_MISMATCH` | 400 | INVALID_ARGUMENT | Step weights do not sum to 1.0 |
| `INVALID_WEIGHT` | 400 | INVALID_ARGUMENT | Weight must be positive |
| `TIMER_ALREADY_RUNNING` | 409 | ALREADY_EXISTS | Timer already started on step |
| `TIMER_NOT_RUNNING` | 409 | FAILED_PRECONDITION | Cannot stop: no active timer |
| `STEP_ALREADY_DONE` | 400 | FAILED_PRECONDITION | Cannot start timer on completed step |
| `ASSIGNEE_NOT_FOUND` | 404 | NOT_FOUND | User ID does not exist |
| `VERSION_CONFLICT` | 409 | ABORTED | Optimistic lock version mismatch |
| `DEPENDENCY_DEPTH_EXCEEDED` | 400 | INVALID_ARGUMENT | Dependency chain exceeds max depth |

---

## 6. API Endpoints

### REST (HTTP/gRPC dual)

#### Task CRUD

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/v1/projects/{projectId}/tasks` | Create task with steps |
| `GET` | `/api/v1/tasks/{taskId}` | Get task with steps and progress |
| `PATCH` | `/api/v1/tasks/{taskId}` | Update task metadata (title, desc) |
| `DELETE` | `/api/v1/tasks/{taskId}` | Delete task (blocked if has dependents) |
| `GET` | `/api/v1/projects/{projectId}/tasks` | List tasks with filters (status, assignee) |

#### Step Management

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/v1/tasks/{taskId}/steps` | Add step to existing task |
| `PATCH` | `/api/v1/tasks/{taskId}/steps/{stepId}` | Update step (name, weight, order) |
| `DELETE` | `/api/v1/tasks/{taskId}/steps/{stepId}` | Remove step (recalculate weights) |
| `GET` | `/api/v1/tasks/{taskId}/steps/{stepId}` | Get single step with time info |

#### Status Transitions

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/v1/tasks/{taskId}/transitions` | Transition task status |
| `POST` | `/api/v1/tasks/{taskId}/steps/{stepId}/transitions` | Transition step status |

#### Dependencies

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/v1/tasks/{taskId}/dependencies` | Add dependency `{dependsOnTaskId}` |
| `DELETE` | `/api/v1/tasks/{taskId}/dependencies/{dependencyId}` | Remove dependency |
| `GET` | `/api/v1/tasks/{taskId}/dependencies` | List all dependencies (depends on) |
| `GET` | `/api/v1/tasks/{taskId}/dependents` | List all tasks that depend on this task |

#### Time Tracking

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/v1/tasks/{taskId}/steps/{stepId}/timer/start` | Start timer |
| `POST` | `/api/v1/tasks/{taskId}/steps/{stepId}/timer/stop` | Stop timer |
| `GET` | `/api/v1/tasks/{taskId}/steps/{stepId}/timer` | Get current timer state |

#### Assignee

| Method | Path | Description |
|---|---|---|
| `PATCH` | `/api/v1/tasks/{taskId}/assignee` | Set/change task assignee |
| `PATCH` | `/api/v1/tasks/{taskId}/steps/{stepId}/assignee` | Set/change step assignee |
| `GET` | `/api/v1/tasks/{taskId}/assignee-history` | Get assignee change history |

#### Progress / Reporting

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/v1/tasks/{taskId}/progress` | Get detailed progress breakdown |
| `GET` | `/api/v1/projects/{projectId}/progress` | Aggregate project progress (rollup) |
| `GET` | `/api/v1/tasks/{taskId}/time-report` | Estimated vs actual time report |

#### Sub-Task Hierarchy

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/v1/tasks/{taskId}/subtasks` | Add existing task as sub-task |
| `GET` | `/api/v1/tasks/{taskId}/subtasks` | List direct sub-tasks with progress |
| `GET` | `/api/v1/tasks/{taskId}/ancestors` | Get ancestor chain to root |

### gRPC Service Definition (proto)

```protobuf
service TaskTrackerService {
    // Tasks
    rpc CreateTask(CreateTaskRequest) returns (Task);
    rpc GetTask(GetTaskRequest) returns (Task);
    rpc UpdateTask(UpdateTaskRequest) returns (Task);
    rpc DeleteTask(DeleteTaskRequest) returns (Empty);
    rpc ListTasks(ListTasksRequest) returns (ListTasksResponse);

    // Steps
    rpc AddStep(AddStepRequest) returns (Step);
    rpc UpdateStep(UpdateStepRequest) returns (Step);
    rpc DeleteStep(DeleteStepRequest) returns (Empty);
    rpc GetStep(GetStepRequest) returns (Step);

    // Transitions
    rpc TransitionTask(TaskTransitionRequest) returns (Task);
    rpc TransitionStep(StepTransitionRequest) returns (Step);

    // Dependencies
    rpc AddDependency(AddDependencyRequest) returns (Dependency);
    rpc RemoveDependency(RemoveDependencyRequest) returns (Empty);
    rpc ListDependencies(ListDependenciesRequest) returns (DependencyList);
    rpc ListDependents(ListDependentsRequest) returns (DependentList);

    // Time
    rpc StartTimer(StartTimerRequest) returns (TimerState);
    rpc StopTimer(StopTimerRequest) returns (TimerState);
    rpc GetTimerState(GetTimerStateRequest) returns (TimerState);

    // Assignee
    rpc UpdateAssignee(UpdateAssigneeRequest) returns (Assignee);
    rpc GetAssigneeHistory(GetAssigneeHistoryRequest) returns (AssigneeHistoryList);

    // Progress
    rpc GetTaskProgress(GetTaskProgressRequest) returns (TaskProgress);
    rpc GetProjectProgress(GetProjectProgressRequest) returns (ProjectProgress);
    rpc GetTimeReport(GetTimeReportRequest) returns (TimeReport);

    // Hierarchy
    rpc AddSubTask(AddSubTaskRequest) returns (Empty);
    rpc ListSubTasks(ListSubTasksRequest) returns (SubTaskList);
    rpc GetAncestors(GetAncestorsRequest) returns (AncestorList);
}
```

---

## 7. NATS Subjects

| Subject | Event Type | Description |
|---|---|---|
| `project-management.task.created` | `project-management.TaskCreated` | New task created |
| `project-management.task.status.changed` | `project-management.TaskStatusChanged` | Task status transition |
| `project-management.step.status.changed` | `project-management.StepStatusChanged` | Step status transition |
| `project-management.progress.updated` | `project-management.ProgressUpdated` | Progress recalculated (most consumed) |
| `project-management.dependency.added` | `project-management.DependencyAdded` | Dependency established |
| `project-management.task.blocked` | `project-management.TaskBlocked` | Task blocked by dependencies |
| `project-management.step.timer.started` | `project-management.StepTimerStarted` | Timer started on step |
| `project-management.step.timer.stopped` | `project-management.StepTimerStopped` | Timer stopped on step |
| `project-management.task.assignee.changed` | `project-management.TaskAssigneeChanged` | Task assignee changed |
| `project-management.step.assignee.changed` | `project-management.StepAssigneeChanged` | Step assignee changed |
| `project-management.subtask.created` | `project-management.SubTaskCreated` | Sub-task relationship created |

---

## 8. Database Schema (PostgreSQL)

```sql
-- Tasks table
CREATE TABLE tasks (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id      UUID NOT NULL,
    title           VARCHAR(200) NOT NULL,
    description     TEXT,
    status          VARCHAR(20) NOT NULL DEFAULT 'TODO',
    parent_task_id  UUID REFERENCES tasks(id),
    assignee_id     VARCHAR(100),
    progress_pct    NUMERIC(5,2) DEFAULT 0.00,
    version         INTEGER NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Steps table
CREATE TABLE steps (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id                 UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    name                    VARCHAR(100) NOT NULL,
    ordinal                 INTEGER NOT NULL,
    weight                  NUMERIC(5,4) NOT NULL DEFAULT 1.0,
    status                  VARCHAR(20) NOT NULL DEFAULT 'TODO',
    estimated_time_minutes  INTEGER DEFAULT 0,
    accumulated_time_minutes INTEGER DEFAULT 0,
    timer_start_time        TIMESTAMPTZ,
    assignee_id             VARCHAR(100),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(task_id, ordinal),
    UNIQUE(task_id, name)
);

-- Task dependencies (DAG)
CREATE TABLE task_dependencies (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id             UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    depends_on_task_id  UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(task_id, depends_on_task_id),
    CHECK(task_id <> depends_on_task_id)
);

-- Assignee history (append-only)
CREATE TABLE assignee_history (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id     UUID NOT NULL REFERENCES tasks(id),
    step_id     UUID REFERENCES steps(id),
    old_assignee VARCHAR(100),
    new_assignee VARCHAR(100) NOT NULL,
    changed_by  VARCHAR(100) NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_tasks_project ON tasks(project_id);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_tasks_assignee ON tasks(assignee_id);
CREATE INDEX idx_steps_task ON steps(task_id);
CREATE INDEX idx_deps_task ON task_dependencies(task_id);
CREATE INDEX idx_deps_depends_on ON task_dependencies(depends_on_task_id);
CREATE INDEX idx_assignee_history_task ON assignee_history(task_id);
```
