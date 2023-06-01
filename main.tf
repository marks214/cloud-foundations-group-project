terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket = "cohort4-group3-cap2-tf-state"
    key    = "tfstate"
    region = "us-west-2"
  }
}

data "aws_s3_bucket" "tf_state_bucket" {
  bucket = "cohort4-group3-cap2-tf-state"
}

# Configure the AWS Provider
provider "aws" {
  region     = "us-west-2"
  access_key = var.access_key
  secret_key = var.secret_key
}

resource "aws_s3_bucket" "json_bucket" {
  bucket = "cohort4-group3-cap2"
}

resource "aws_s3_object" "todo-data" {
  bucket = aws_s3_bucket.json_bucket.id
  key    = "todo-data.json"
  source = "todo-data.json"
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "s3_access" {
  statement {
    effect = "Allow"

    actions = ["s3:GetObject"]

    resources = [
      "arn:aws:s3:::*"
    ]
  }
}

resource "aws_iam_role" "iam_for_lambda" {
  name               = "cohort4-group3-cap2-get-todos-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  inline_policy {
    name   = "cohort4-group3-cap2-s3-policy-new"
    policy = data.aws_iam_policy_document.s3_access.json
  }
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "lambda.py"
  output_path = "lambda_function_payload.zip"
}

resource "aws_lambda_function" "get_todos" {
  filename      = "lambda_function_payload.zip"
  function_name = "cohort4-group3-cap2-get-todos"
  role          = aws_iam_role.iam_for_lambda.arn
  handler       = "lambda.lambda_handler"

  source_code_hash = data.archive_file.lambda.output_base64sha256

  runtime = "python3.9"
}

resource "aws_lambda_permission" "apigw-post" {
  statement_id  = "cohort4-group4-cap2-AllowAPIGatewayInvokePOST"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_todos.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_api_gateway_rest_api.rest_api.execution_arn}/*"
}

resource "aws_api_gateway_rest_api" "rest_api" {
  name = "cohort4-group3-cap2-api"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "api_gw_todo_resource" {
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "get-todo"
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
}

resource "aws_api_gateway_method" "api_gw_todo_method" {
  authorization = "NONE"
  http_method   = "GET"
  resource_id   = aws_api_gateway_resource.api_gw_todo_resource.id
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
}

resource "aws_api_gateway_integration" "api_gw_todo_intg" {
  http_method             = aws_api_gateway_method.api_gw_todo_method.http_method
  resource_id             = aws_api_gateway_resource.api_gw_todo_resource.id
  rest_api_id             = aws_api_gateway_rest_api.rest_api.id
  type                    = "AWS"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.get_todos.invoke_arn
}

resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  resource_id = aws_api_gateway_resource.api_gw_todo_resource.id
  http_method = aws_api_gateway_method.api_gw_todo_method.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true,
    "method.response.header.Access-Control-Allow-Methods" = true,
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "api_gw_intg_resp" {
  rest_api_id      = aws_api_gateway_rest_api.rest_api.id
  resource_id      = aws_api_gateway_resource.api_gw_todo_resource.id
  http_method      = aws_api_gateway_method.api_gw_todo_method.http_method
  status_code      = aws_api_gateway_method_response.response_200.status_code
  content_handling = "CONVERT_TO_TEXT"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'",
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'",
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  # depends_on = [aws_api_gateway_method_response.response_200, aws_api_gateway_method.api_gw_todo_method, aws_api_gateway_integration.api_gw_todo_intg]
}

resource "aws_api_gateway_deployment" "api_gw_deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id

  triggers = {
    # NOTE: The configuration below will satisfy ordering considerations,
    #       but not pick up all future REST API changes. More advanced patterns
    #       are possible, such as using the filesha1() function against the
    #       Terraform configuration file(s) or removing the .id references to
    #       calculate a hash against whole resources. Be aware that using whole
    #       resources will show a difference after the initial implementation.
    #       It will stabilize to only change when resources change afterwards.
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.api_gw_todo_resource.id,
      aws_api_gateway_method.api_gw_todo_method.id,
      aws_api_gateway_integration.api_gw_todo_intg.id,
      aws_api_gateway_integration_response.api_gw_intg_resp.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "api_gw_stage_prod" {
  deployment_id = aws_api_gateway_deployment.api_gw_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  stage_name    = "prod"
}

resource "aws_ecr_repository" "ecr_repo" {
  name                 = "cohort4-group3-cap2"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }
}

resource "aws_iam_role" "codebuild_role" {
  name               = "cohort4-group3-cap2-TestCodeBuildRole"
  assume_role_policy = data.aws_iam_policy_document.codebuild_role_policy.json

  inline_policy {
    name   = "cohort4-group3-cap2-codebuild-log-policy"
    policy = data.aws_iam_policy_document.codebuild_log_policy.json
  }
}

data "aws_iam_policy_document" "codebuild_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "codebuild_log_policy" {
  statement {
    effect    = "Allow"
    actions   = ["logs:*"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObjectAcl",
      "s3:PutObject",
    ]

    resources = [
      aws_s3_bucket.codepipeline_bucket.arn,
      "${aws_s3_bucket.codepipeline_bucket.arn}/*",
      data.aws_s3_bucket.tf_state_bucket.arn,
      "${data.aws_s3_bucket.tf_state_bucket.arn}/*"
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:us-west-2:962804699607:secret:cohort4-group3-cap2-secret-BiI0vD"]
  }
}


resource "aws_iam_role_policy_attachment" "codebuild_role_policy" {
  role       = aws_iam_role.codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"

}

# -------------------------CODEBUILD-------------------------------

resource "aws_codebuild_project" "codebuild_project" {
  name           = "cohort4-group3-cap2"
  description    = "cohort4-group3-cap2 codebuild_project"
  build_timeout  = "60"
  queued_timeout = "480"

  service_role = aws_iam_role.codebuild_role.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  cache {
    type = "NO_CACHE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:4.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

  }

  source {
    type     = "GITHUB"
    location = "https://github.com/marks214/cloud-foundations-group-project.git"
  }

}

# -------------------------CODEPIPELINE-------------------------------
resource "aws_s3_bucket" "codepipeline_bucket" {
  bucket = "cohort4-group3-cap2-codepipeline-bucket"
}

data "aws_iam_policy_document" "codepipeline_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codepipeline_role" {
  name               = "cohort4-group3-cap2-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume_role.json
}

resource "aws_codestarconnections_connection" "codestar_connection" {
  name          = "cohort4-group3-cap2-connect"
  provider_type = "GitHub"
}

data "aws_iam_policy_document" "codepipeline_policy" {
  statement {
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetBucketVersioning",
      "s3:PutObjectAcl",
      "s3:PutObject",
    ]

    resources = [
      aws_s3_bucket.codepipeline_bucket.arn,
      "${aws_s3_bucket.codepipeline_bucket.arn}/*",
      data.aws_s3_bucket.tf_state_bucket.arn,
      "${data.aws_s3_bucket.tf_state_bucket.arn}/*"
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["codestar-connections:UseConnection"]
    resources = [aws_codestarconnections_connection.codestar_connection.arn]
  }

  statement {
    effect = "Allow"

    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "ecs:*",
      "cloudwatch:*",
      "iam:PassRole"
    ]

    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:us-west-2:962804699607:secret:cohort4-group3-cap2-secret-BiI0vD"]
  }
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name   = "cohort4-group3-cap2-codepipeline_policy"
  role   = aws_iam_role.codepipeline_role.id
  policy = data.aws_iam_policy_document.codepipeline_policy.json
}


resource "aws_codepipeline" "codepipeline_project" {
  name     = "cohort4-group3-cap2"
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.codepipeline_bucket.bucket
    type     = "S3"

  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = aws_codestarconnections_connection.codestar_connection.arn
        FullRepositoryId     = "marks214/cloud-foundations-group-project"
        BranchName           = "main"
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.codebuild_project.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      input_artifacts = ["build_output"]
      version         = "1"

      configuration = {
        ClusterName = aws_ecs_cluster.todo-cluster.name
        ServiceName = aws_ecs_service.todo_service.name
      }
    }
  }
}
