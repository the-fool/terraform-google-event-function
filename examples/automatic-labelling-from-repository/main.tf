/**
 * Copyright 2019 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

terraform {
  required_version = "~> 0.11.0"
}

provider "archive" {
  version = "~> 1.0"
}

provider "google" {
  version = "~> 2.1"
}

provider "random" {
  version = "~> 2.0"
}

provider "null" {
  version = "~> 1.0"
}

resource "random_pet" "main" {
  separator = "-"
}

resource "google_sourcerepo_repository" "main" {
  name    = "${random_pet.main.id}"
  project = "${var.project_id}"
}

resource "null_resource" "configure_repository" {
  triggers {
    repository_url = "${google_sourcerepo_repository.main.url}"
  }

  provisioner "local-exec" {
    command = "${path.module}/scripts/configure_repository.sh"

    environment {
      REMOTE_URL                = "${google_sourcerepo_repository.main.url}"
      REPOSITORY_DIRECTORY      = "${path.module}/function_source"
      REPOSITORY_COPY_DIRECTORY = "${path.module}/function_source_copy"
    }
  }
}

data "null_data_source" "main" {
  inputs = {
    source_repository_url = "https://source.developers.google.com/projects/${var.project_id}/repos/${random_pet.main.id}/moveable-aliases/master/paths/"
  }

  depends_on = ["null_resource.configure_repository"]
}

module "event_project_log_entry" {
  source = "../../modules/event-project-log-entry"

  filter = "${
    join(
      " AND ",
      list(
        "protoPayload.@type=\"type.googleapis.com/google.cloud.audit.AuditLog\"",
        "protoPayload.methodName:insert",
        "operation.first=true",
      )
    )
  }"

  name       = "${random_pet.main.id}"
  project_id = "${var.project_id}"
}

module "function_sourced_from_repository" {
  source = "../../modules/function-sourced-from-repository"

  description = "Labels resource with owner information."
  entry_point = "labelResource"

  environment_variables = {
    LABEL_KEY = "principal-email"
  }

  event_trigger         = "${module.event_project_log_entry.function_event_trigger}"
  name                  = "${random_pet.main.id}"
  project_id            = "${var.project_id}"
  region                = "${var.region}"
  source_repository_url = "${data.null_data_source.main.outputs["source_repository_url"]}"
}

resource "null_resource" "wait_for_function" {
  provisioner "local-exec" {
    command = "sleep 60"
  }

  depends_on = ["module.function_sourced_from_repository"]
}

resource "google_compute_instance" "main" {
  boot_disk = {
    initialize_params = {
      image = "debian-cloud/debian-9"
    }
  }

  machine_type = "f1-micro"
  name         = "unlabelled"
  zone         = "${var.zone}"

  network_interface = {
    network = "default"
  }

  project = "${var.project_id}"

  depends_on = ["null_resource.wait_for_function"]
}
