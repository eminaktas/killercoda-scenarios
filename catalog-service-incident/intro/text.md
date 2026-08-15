# A production incident

The two-node cluster is being prepared with an application incident for you to
investigate. The terminal will become available when the environment is ready.

You have root access to the environment and full administrative access to the
cluster.

The terminal runs on the outer Ubuntu host. Use `kubectl` there for Kubernetes
operations. The cluster nodes run as Docker containers, so commands that
inspect a node's network namespace must be run with `docker exec`.
