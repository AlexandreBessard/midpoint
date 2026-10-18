# Written as a JSON file (rather than inlined into a shell one-liner in the
# `aws ecs run-task --overrides` output) to avoid stacking JSON-in-shell
# quoting on top of the shell-in-shell quoting the run-sql command already
# needs - the exact kind of nested escaping that's bitten this project's
# other scripts (see import-config-ecs.sh / docker-compose.yml comments).
resource "local_file" "bootstrap_overrides" {
  filename = "${path.module}/generated/bootstrap-overrides.json"

  content = jsonencode({
    containerOverrides = [
      {
        name = "midpoint-import"
        command = [
          "sh", "-c",
          join(" && ", [
            "cd /opt/midpoint",
            "./bin/ninja.sh run-sql --mode REPOSITORY --create --jdbc-url \"$MIDPOINT_JDBC_URL\" --jdbc-username \"$MIDPOINT_JDBC_USERNAME\" --jdbc-password \"$MIDPOINT_JDBC_PASSWORD\"",
            "./bin/ninja.sh run-sql --mode AUDIT --create --jdbc-url \"$MIDPOINT_JDBC_URL\" --jdbc-username \"$MIDPOINT_JDBC_USERNAME\" --jdbc-password \"$MIDPOINT_JDBC_PASSWORD\"",
          ])
        ]
      }
    ]
  })
}
