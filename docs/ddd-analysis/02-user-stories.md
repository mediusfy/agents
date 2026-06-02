# Rufkis — User Stories

> All stories follow `BC-NN` format. Bounded Context prefixes: BOARD, RES, CLUSTER, AGENT, AUTO, GITOPS, IDENT, NOTIF, FIN, AUDIT, RT, NAV.

---

## Board & Workload Viewing

### BOARD-01: Visual Board with Resource Rows
**As a** Kubernetes operator  
**I want** to see all my K8s resources displayed as rows in a configurable board view  
**So that** I can quickly understand the state of my cluster at a glance

```gherkin
Given I am authenticated and have access to cluster "prod-us-east"
When I open the Rufkis board view
Then I see a table layout where each row represents a Kubernetes resource
And the default columns displayed are: Name, Type, Namespace, Status, Age
And each row has a checkbox for multi-select
And the board title reflects the current view name and cluster

Given the cluster contains 3 Deployments, 5 Pods, and 2 Services
When the board renders
Then exactly 10 rows are shown
And resources are grouped under collapsible headers by resource type
```

**Event Triggers:** `board.BoardOpened`, `board.ResourcesFetched`, `board.BoardRendered`

---

### BOARD-02: Custom Columns and Reordering
**As a** platform engineer  
**I want** to add, remove, and reorder columns on the board  
**So that** I can see the exact attributes I care about for each resource

```gherkin
Given I am viewing a board with default columns: Name, Status, Namespace, Age
When I open the column configuration panel
And I add the "CPU Usage" column
And I remove the "Age" column
And I reorder "Status" to be the first column
Then the board shows columns in order: Status, Name, Namespace, CPU Usage

Given the "Labels" column is added
When the board refreshes
Then each resource row shows a comma-separated list of labels in that column
And labels are truncated with a "+N more" indicator if more than 3
```

**Event Triggers:** `board.ColumnLayoutChanged`

---

### BOARD-03: Filtering and Grouping
**As a** SRE  
**I want** to filter resources by attribute and group them by column values  
**So that** I can narrow down to specific sets of resources

```gherkin
Given the board displays 50 resources across 3 namespaces
When I apply a filter: namespace equals "production"
Then only resources in the "production" namespace are shown
And the row count decreases to 15

Given 15 resources are visible
When I select "Group by: Namespace"
Then resources are organized into 1 group: "production"
And each group header shows the group name and resource count

Given I apply a two-level filter: status = "CrashLoopBackOff" AND namespace = "production"
When the board re-renders
Then only matching resources are displayed
And a filter badge shows: "2 filters active"
```

**Event Triggers:** `board.BoardFilterApplied`

---

### BOARD-04: Multiple Board Layouts
**As a** team lead  
**I want** to switch between board, Kanban, and timeline views  
**So that** I can understand resource state from different perspectives

```gherkin
Given I am viewing the main board layout
When I select "Kanban View" from the layout switcher
Then resources are rendered as cards in columns grouped by their Status
And the columns are: Running, Pending, Succeeded, Failed, Unknown, CrashLoopBackOff
And I can drag a card from "Pending" to "Running" to update the resource status

Given I select "Timeline View"
When the view renders
Then Deployments and StatefulSets appear as horizontal bars on a time axis
And the bar length corresponds to the resource's age
And future rollout windows are shown as dashed overlays
```

**Event Triggers:** `board.BoardViewChanged`

---

## Resource Detail & Interaction

### RES-01: Sliding Detail Drawer
**As a** Kubernetes operator  
**I want** to open a sliding drawer with full resource info when I click a row  
**So that** I can inspect YAML, events, logs, and metrics without leaving the board

```gherkin
Given I am viewing the board with a list of Pods
When I click on a Pod row with name "nginx-7d8f9c"
Then a sliding drawer opens from the right side of the screen
And the drawer header shows: "nginx-7d8f9c • Pod • production"
And the drawer contains tabs: Overview, YAML, Events, Logs, Metrics
And the Overview tab shows: status, node, IP, restart count, conditions, labels, annotations

Given the YAML tab is selected
When the drawer loads
Then the full Kubernetes manifest is displayed in a syntax-highlighted code block
And a "Copy" button is available
And a "Raw" toggle shows the unformatted YAML
```

**Event Triggers:** `resources.DetailDrawerOpened`, `resources.ResourceDetailLoaded`

---

### RES-02: Inline Resource Editing
**As a** platform engineer  
**I want** to edit resource attributes directly from the board  
**So that** I can make quick changes without using kubectl

```gherkin
Given I am viewing a Deployment named "api-server" with 3 replicas
When I double-click the "Replicas" cell for that row
Then the cell becomes editable as a number input
When I change the value from "3" to "5" and press Enter
Then a confirmation dialog appears: "Scale deployment api-server from 3 to 5 replicas?"
When I confirm
Then the deployment is scaled to 5 replicas
And the cell updates to show "5" with a subtle animation
And a success toast appears

Given I edit the "Labels" cell for a Node named "worker-2"
When I add a label "tier=spot"
Then a diff preview shows the change
And I can confirm or cancel
When I confirm
Then the Node is labeled via the Kubernetes API
```

**Event Triggers:** `resources.ResourceInlineEdited`, `resources.ScaleActionRequested`

---

### RES-03: Resource Logs & Metrics
**As a** debugger  
**I want** to view live logs and CPU/memory metrics for a pod  
**So that** I can troubleshoot issues without switching to kubectl or other tools

```gherkin
Given I have the detail drawer open for Pod "auth-service-6b4f7c"
When I select the "Logs" tab
Then I see streaming logs from the pod's main container
And there is a dropdown to switch between containers (if multiple)
And there are controls: Pause/Resume, Download, Tail lines (100/500/1000), Search
And timestamps are shown on each log line

Given I select the "Metrics" tab
When the drawer loads
Then I see a line chart showing CPU usage over the last 1 hour (default)
And a second chart showing Memory usage over the same period
And I can change the time range: 1h, 6h, 24h, 7d
And there is a "Refresh" button
```

**Event Triggers:** `resources.ResourceMetricsViewed`, `resources.ResourceLogsViewed`

---

### RES-04: Resource Events Timeline
**As a** troubleshooter  
**I want** to see a chronological list of K8s events for a resource  
**So that** I can understand what's happening with a failing resource

```gherkin
Given I have the detail drawer open for a resource
When I select the "Events" tab
Then I see a chronological list of Kubernetes events for that resource
And each event shows: Type (Normal/Warning), Reason, Message, Source, Count, Last Seen
And Warning events are highlighted in red
And there is a filter to show only warnings
```

**Event Triggers:** `resources.ResourceEventsViewed`

---

## Cluster Management

### CLUSTER-01: Multi-Cluster Registration
**As a** cluster admin  
**I want** to register clusters from different cloud providers  
**So that** I can manage all my Kubernetes clusters from one console

```gherkin
Given I have admin privileges in the Identity context
When I click "Add Cluster" in the cluster management panel
Then I see a form requesting: Cluster Name, Provider (EKS/GKE/AKS/On-Prem/Generic), Region, API Endpoint, Kubeconfig or OIDC params
And a "Data Residency Zone" dropdown with options: US-East, US-West, EU-Central, EU-West, AP-Southeast, Custom
And a toggle: "Use Agent (recommended)" vs "Direct API Access"

Given I select "EKS" as provider
When I fill in the AWS account ID and cluster name
Then I am prompted to authenticate via AWS IAM role assumption
And a connection test is performed
And the cluster appears in the cluster list with a green "Connected" badge
```

**Event Triggers:** `clusters.ClusterRegistered`, `clusters.ClusterConnectionTested`

---

### CLUSTER-02: Cross-Cluster Resource Views
**As a** multi-cluster operator  
**I want** to view resources across multiple clusters in one board  
**So that** I can compare state across environments and regions

```gherkin
Given I have 3 registered clusters: "prod-us-east", "prod-eu-west", "staging-us-east"
When I create a new board with a "Cross-Cluster" data source
And I select all 3 clusters as sources
Then the board shows resources from all 3 clusters
And each row has a "Cluster" column showing which cluster the resource belongs to
And I can filter by cluster

Given I group by "Cluster" on the cross-cluster board
When the board renders
Then resources are organized into groups: "prod-us-east", "prod-eu-west", "staging-us-east"
And each group header shows the cluster health status (green/yellow/red)
```

**Event Triggers:** `clusters.CrossClusterViewCreated`

---

## Agent Deployment & Orchestration

### AGENT-01: Agent Deployment
**As a** cluster admin  
**I want** to deploy Rufkis agents into my target clusters  
**So that** the console can receive real-time state updates without direct API access

```gherkin
Given I have registered cluster "prod-us-east" with "Use Agent" mode
When I navigate to the cluster's "Agent" tab
Then I see installation instructions for: Helm chart, kubectl apply, Operator
And a "Deploy Agent" button generates a one-liner install command

Given the agent is deployed
When the agent connects to the central console for the first time
Then the cluster status changes to "Connected" within 30 seconds
And the agent version is displayed
And the agent reports: cluster node count, API version, add-ons installed

Given the agent heartbeat is expected every 15 seconds
When no heartbeat is received for 60 seconds
Then the cluster status changes to "Disconnected"
And an alert is created in the Notifications context
```

**Event Triggers:** `clusters.AgentInstallationInstructionsViewed`, `agent.AgentConnected`, `agent.AgentDisconnected`

---

### AGENT-02: Agent-Based Resource Reporting
**As a** console user  
**I want** the agent to watch and report resource state changes in real-time  
**So that** the board view stays up-to-date automatically

```gherkin
Given the Rufkis agent is running in cluster "prod-us-east"
When a new Pod is created in the cluster
Then the agent detects the change within 5 seconds
And sends a state delta to the central console
And the board view updates to show the new Pod without page refresh

Given a Deployment is scaled from 5 to 10 replicas
When the agent reports the change
Then the board updates the Replicas column for that Deployment
And a brief visual indicator (pulse animation) highlights the changed cell
```

**Event Triggers:** `agent.ResourceStateChanged`, `realtime.ResourceUpdated`

---

## Automation

### AUTO-01: Create Automation Recipes
**As a** SRE  
**I want** to build automation recipes with triggers, conditions, and actions  
**So that** common operational tasks are handled automatically

```gherkin
Given I have permission to create automations
When I click "New Automation Recipe"
Then I see a recipe builder with sections: Name, Description, Trigger, Conditions, Actions, Target Resources
And I can choose from trigger types: Resource State Change, Metric Threshold, Schedule (Cron), Webhook, Audit Event

Given I select "Metric Threshold" trigger
When I configure: CPU > 80% for 5 minutes on any Deployment
And I add condition: namespace equals "production"
And I add action: "Scale Up" with parameters: replicas = current + 2, maxReplicas = 20
Then the recipe is saved with status "Active"
And a confirmation shows the recipe evaluation interval
```

**Event Triggers:** `automation.RecipeEditorOpened`, `automation.RecipeCreated`

---

### AUTO-02: Auto-Remediation Execution
**As a** platform engineer  
**I want** recipes to execute actions automatically when conditions are met  
**So that** issues are remediated without manual intervention

```gherkin
Given an active automation recipe: "Restart CrashLoopBackOff Pods"
With trigger: Resource State Change = "CrashLoopBackOff"
And action: "Restart Pod"
When a Pod enters CrashLoopBackOff state
Then the recipe detects the condition within 30 seconds
And executes: delete the pod to force recreation
And an audit event is logged
And a notification is sent via the configured channel

Given the same pod enters CrashLoopBackOff again within 5 minutes
When the recipe re-evaluates
Then the action is NOT executed (backoff: 5 min cooldown)
And a warning is logged: "Cooldown active - recipe '...' skipped execution for pod nginx-7d8"
```

**Event Triggers:** `automation.RecipeActionExecuted`, `automation.RecipeCooldownActivated`

---

## GitOps Integration

### GITOPS-01: Create PR from Console Changes
**As a** platform engineer  
**I want** to create Git PRs from changes I make in the console  
**So that** infrastructure changes are version-controlled and reviewable

```gherkin
Given I have edited a ConfigMap via inline editing on the board
When I click "Create PR" in the change confirmation dialog
Then I am prompted to select: Git Repository, Branch, Commit message
And a diff preview shows: the current in-cluster manifest vs the proposed change

Given I confirm the PR creation
When the system processes the request
Then a new branch is created from the base branch
And the change is committed to that branch
And a Pull Request is opened against the base branch
And I am shown a link to the PR on GitHub/GitLab/Bitbucket
```

**Event Triggers:** `gitops.PullRequestCreated`

---

### GITOPS-02: GitOps Sync Status
**As a** GitOps practitioner  
**I want** to view sync status and drift detection  
**So that** I know when cluster state diverges from Git-declared state

```gherkin
Given a cluster is managed via GitOps (ArgoCD/Flux)
When I open the GitOps tab in the cluster detail view
Then I see: Sync Status (Synced/OutOfSync/Unknown), Last Sync Time, Commit SHA, App Name
And a list of resources with drift: expected (from Git) vs actual (in cluster)

Given there is drift detected for a Deployment
When I click "View Diff"
Then I see a side-by-side comparison of the Git manifest and the cluster manifest
And I have options: "Sync from Git" or "Sync from Cluster" or "Create PR to reconcile"
```

**Event Triggers:** `gitops.DriftDetected`

---

## Identity & Workspace

### IDENT-01: Team Workspaces with RBAC
**As a** workspace admin  
**I want** to create workspaces with role-based access control  
**So that** different teams get appropriate access to clusters and resources

```gherkin
Given I am a workspace admin
When I create a new workspace named "Platform Engineering"
Then the workspace is created with a default "admin" role
And I can invite users via email or SSO group sync

Given I navigate to "Team Settings" in the workspace
When I add user "alice@company.com" with role "Editor"
And I add user "bob@company.com" with role "Viewer"
Then alice can: create boards, edit resources, create automations
And bob can: view boards, open detail drawers, but cannot make changes
```

**Event Triggers:** `identity.WorkspaceCreated`, `identity.WorkspaceRoleAssigned`

---

## Notifications

### NOTIF-01: Notification Channel Configuration
**As a** platform operator  
**I want** to configure Slack, PagerDuty, and email notification channels  
**So that** alerts reach the right people through the right channels

```gherkin
Given I navigate to Settings > Notifications
When I click "Add Channel" and select "Slack"
Then I am prompted to authenticate via OAuth with Slack
And I select which Slack channel to post to: #kubernetes-alerts
And I can test the connection with a "Send Test" button

Given I add a PagerDuty channel
When I enter the PagerDuty service integration key
Then a test alert is triggered to verify the integration
```

**Event Triggers:** `notifications.NotificationChannelConfigured`

---

### NOTIF-02: Condition-Based Alerts
**As an** on-call engineer  
**I want** to receive notifications when certain resource conditions occur  
**So that** I can respond to incidents promptly

```gherkin
Given I have configured a Slack channel "#k8s-alerts"
And a notification rule: "Send alert when any Pod enters CrashLoopBackOff in production"
When a Pod in the production namespace enters CrashLoopBackOff
Then within 30 seconds, a Slack message is posted to #k8s-alerts
And the message includes: Pod name, namespace, cluster, restarts count, last error log snippet
And a link to open the resource in Rufkis

Given the same alert fires 3 times within 5 minutes
When the notification rule evaluates
Then alerts are deduplicated: only 1 message is sent with an "x3 occurrences" badge
```

**Event Triggers:** `notifications.NotificationSent`, `notifications.AlertDeduplicated`

---

## FinOps

### FIN-01: Cost Estimates per Namespace and Cluster
**As a** FinOps practitioner  
**I want** to see cost estimates broken down by namespace, deployment, and cluster  
**So that** I can understand and optimize infrastructure spending

```gherkin
Given I have access to FinOps features
When I navigate to the "Costs" tab for cluster "prod-us-east"
Then I see a breakdown: Total monthly cost estimate, Cost by namespace, Cost by deployment, Cost by node pool
And the data is displayed as bar charts and a table

Given I select namespace "production"
When the detail view loads
Then I see each Deployment's estimated monthly cost
And the cost components: CPU, Memory, Storage, Network (egress)
And a comparison to the previous month's cost

Given the cluster is on AWS EKS
When the cost data is calculated
Then it uses: EC2 instance pricing, EBS volume costs, data transfer costs, and any spot/reserved instance discounts
And a note indicates: "Costs are estimates based on current usage and may differ from actual bills"
```

**Event Triggers:** `finops.CostReportGenerated`

---

## Audit

### AUDIT-01: Full Audit Log of User Actions
**As a** security/compliance officer  
**I want** a full audit trail of all user actions  
**So that** I can investigate security incidents and meet compliance requirements

```gherkin
Given I am a workspace admin
When I navigate to the Audit Log
Then I see a chronological table of all actions with columns: Timestamp, User, Action, Resource, Cluster, Workspace, IP Address, Status

Given I search for "user:alice@company.com action:delete"
When the results load
Then I see all delete operations performed by alice
And each entry shows the full diff (before/after) for the deleted resource

Given an audit retention policy of 90 days
When I view logs older than 90 days
Then the page shows: "Logs older than 90 days are archived. Contact support for retrieval."
```

**Event Triggers:** `audit.UserActionRecorded`, `audit.AuditLogArchived`

---

## Real-time Updates

### RT-01: Live Resource State Updates via WebSocket
**As a** console user  
**I want** the board to update in real-time without page refreshes  
**So that** I always see the current state of my cluster

```gherkin
Given I have the board view open for cluster "prod-us-east"
When a Pod in the cluster transitions from "Running" to "CrashLoopBackOff"
Then the board updates within 2 seconds without page refresh
And the status cell for that Pod smoothly transitions with a color change (green -> red)
And a small notification badge appears on the row: "State changed"

Given I open the detail drawer for a Deployment
When the Deployment is scaled by another user
Then the YAML tab updates in real-time showing the new replica count
And a subtle indicator "Live" blinks in the drawer header

Given the WebSocket connection drops
When the client detects disconnection
Then a banner appears: "Connection lost - reconnecting..."
And the board shows a "Last updated: X seconds ago" timestamp
And when reconnected, a full state sync is performed
```

**Event Triggers:** `realtime.ResourceUpdated`, `realtime.ClientReconnected`, `realtime.ConnectionLost`

---

## Navigation & Favorites

### NAV-01: Command Palette (Cmd+K)
**As a** power user  
**I want** a Cmd+K command palette for quick navigation and actions  
**So that** I can work efficiently without reaching for the mouse

```gherkin
Given I am on any page in the console
When I press Cmd+K (Mac) or Ctrl+K (Windows/Linux)
Then a command palette overlay opens with a search input focused
And suggestions appear: recently accessed resources, views, clusters, and actions
And the palette shows categorized commands: Navigate, Actions, Create, Run

Given I type "scale deploy api" in the command palette
When results load
Then I see: "Scale Deployment api-server in prod-us-east" as an action
And "/Cluster/prod-us-east/Deployment/api-server" as a navigation link
And "View Deployment api-server" as another option

Given I select "Scale Deployment api-server in prod-us-east"
When the action executes
Then a scaling dialog opens directly from the palette
And I can enter the desired replica count without leaving the palette
```

**Event Triggers:** `navigation.CommandPaletteOpened`, `navigation.CommandPaletteActionExecuted`

---

### NAV-02: Bookmarks and Favorites
**As a** frequent user  
**I want** to bookmark frequently accessed resources and views  
**So that** I can quickly navigate back to them

```gherkin
Given I am viewing a board named "Production Overview"
When I click the "Bookmark" star icon
Then the board is added to my favorites
And it appears under "Favorites" in the sidebar

Given I have bookmarked 3 resources and 2 views
When I open the "Favorites" panel
Then I see them grouped as: Views (2), Resources (3)
And I can reorder them via drag-and-drop
And I can remove a favorite by clicking the filled star

Given I bookmark a specific Pod "nginx-7d8f9c" in cluster "prod-us-east"
When I navigate to Favorites
Then the Pod shows with a deep-link that opens the detail drawer directly
```

**Event Triggers:** `navigation.BookmarkCreated`, `navigation.BookmarkRemoved`
