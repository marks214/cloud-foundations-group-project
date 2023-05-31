import boto3
import json


def lambda_handler(event, context):
    s3 = boto3.client("s3")
    bucket = "cohort4-group3-cap2"
    key = "todo-data.json"
    response = s3.get_object(Bucket=bucket, Key=key)
    json_data = response["Body"].read().decode("utf-8")
    json_content = json.loads(json_data)
    return {
    'statusCode': 200,
    'body': json_content
}