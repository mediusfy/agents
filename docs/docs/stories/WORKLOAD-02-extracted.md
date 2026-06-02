

# WORKLOAD-02: Scale a Deployment Directly from the Inline Detail Sheet

**Source:** RUFKIS-01 Workload Management Epic

---

## Story ID
WORKLOAD-02

## Title
Scale a Deployment Directly from the Inline Detail Sheet

## Description
As an operator managing workloads during an incident, I want to scale a deployment (e.g., increase or decrease replica count) directly from the inline detail sheet without navigating away from the workload list view, so that I can quickly adjust capacity during incidents.

---

## Acceptance Criteria (Gherkin)

```gherkin
Feature: Scale Deployment from Inline Detail Sheet

  Scenario: Operator increases replica count from inline detail sheet
    Given the operator is viewing the workload list view
    When the operator opens the inline detail sheet for a deployment
    And the operator modifies the replica count field from "3" to "5"
    And the operator clicks the "Apply" or "Save" button
    Then the deployment should scale to 5 replicas
    And the inline detail sheet should reflect the updated replica count
    And the workload list view should reflect the updated replica count

  Scenario: Operator decreases replica count from inline detail sheet
    Given the operator is viewing the workload list view
    When the operator opens the inline detail sheet for a deployment
    And the operator modifies the replica count field from "5" to "2"
    And the operator clicks the "Apply" or "Save" button
    Then the deployment should scale to 2 replicas
    And the inline detail sheet should reflect the updated replica count
    And the workload list view should reflect the updated replica count

  Scenario: Operator enters an invalid replica count
    Given the operator is viewing the workload list view
    When the operator opens the inline detail sheet for a deployment
    And the operator modifies the replica count field to "-1"
    Then the system should display a validation error
    And the replica count should not be applied
    And the deployment should remain at its previous replica count

  Scenario: Operator cancels scaling operation
    Given the operator is viewing the workload list view
    When the operator opens the inline detail sheet for a deployment
    And the operator modifies the replica count field
    And the operator clicks the "Cancel" button
    Then the replica count should revert to its original value
    And the inline detail sheet should close
    And the deployment should remain unchanged
```

## Event Triggers (from story notes)
- Incident response requiring immediate scaling of a deployment
- Capacity management during traffic spikes
- Rollback or scale-down after incident resolution
- Manual adjustment during maintenance windows

## Notes
- Scaling should be performed via the Kubernetes API (e.g., updating the `spec.replicas` field on the Deployment resource)
- The inline detail sheet should provide real-time feedback on the scaling operation (e.g., loading state, success confirmation, error message)
- Validation must ensure replica count is a non-negative integer (zero is allowed for scale-to-zero scenarios)
- The change should be reflected in both the inline detail sheet and the parent list view immediately after successful application
- Undo/rollback of the scaling action is out of scope for this story but may be addressed in a future iteration
- Consider eventual consistency: the list view may show the old count briefly until the API confirms the change
