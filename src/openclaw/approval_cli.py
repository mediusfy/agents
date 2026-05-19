import redis
import json
import click
from openclaw.task_queue import Task, task_queue

@click.group()
def cli():
    """A CLI for managing the OpenClaw approval queue."""
    pass

@cli.command()
def list():
    """List all tasks pending approval."""
    pending_tasks = task_queue.redis.lrange(task_queue.pending_approval_queue_name, 0, -1)
    if not pending_tasks:
        click.echo("No tasks are pending approval.")
        return
    
    for i, task_json in enumerate(pending_tasks):
        task = Task(**json.loads(task_json))
        click.echo(f"[{i}] Task ID: {task.id}")
        click.echo(f"    Capability: {task.capability}")
        click.echo(f"    Prompt: {task.prompt}")
        click.echo("-" * 20)

@cli.command()
@click.argument('task_index', type=int)
def approve(task_index):
    """Approve a task and move it to the main queue."""
    task_json = task_queue.redis.lindex(task_queue.pending_approval_queue_name, task_index)
    if not task_json:
        click.echo(f"No task found at index {task_index}.")
        return
        
    task = Task(**json.loads(task_json))
    task_queue.publish_task(task)
    task_queue.redis.lrem(task_queue.pending_approval_queue_name, 1, task_json)
    click.echo(f"Task {task.id} approved and moved to the main queue.")

@cli.command()
@click.argument('task_index', type=int)
def deny(task_index):
    """Deny a task and remove it from the queue."""
    task_json = task_queue.redis.lindex(task_queue.pending_approval_queue_name, task_index)
    if not task_json:
        click.echo(f"No task found at index {task_index}.")
        return
        
    task = Task(**json.loads(task_json))
    task_queue.redis.lrem(task_queue.pending_approval_queue_name, 1, task_json)
    click.echo(f"Task {task.id} denied and removed from the queue.")

if __name__ == "__main__":
    cli()
