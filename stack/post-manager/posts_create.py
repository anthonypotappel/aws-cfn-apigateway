
import time
import json
import boto3

try:
    dynamodb = boto3.resource('dynamodb')
except Exception as e:
    _raise(Exception, "Message:" + str(e))

value = lambda dictionary, key: dictionary[key] if key in dictionary else ""

def _raise(exception, error):
    raise exception(error)

def create_user(payload, stagevars, context):
    table = dynamodb.Table(stagevars['DynamoDBTable'])

    time_in_ms = int(time.time() * 10**3)

    record = {
      "UserId": f"{payload['UserId']}-{str(time_in_ms)[-1]}",
      "EventTime": time_in_ms,
      "SourceIP": value(context, 'source-ip'),
      "UserAgent": value(context, 'user-agent'),
      "Message": payload['Message']
    }

    # add max 3 tags to item
    if isinstance(payload.get('Tags'), list):
      record.update({
        f"Tag{str(index)}": str(value)
        for index, value in enumerate(payload['Tags'][0:3])
      })

    table.put_item(Item=record)
    return record

def handler(event,_):
    try:
        record = create_user(event['body-json'],
                             event['stage-variables'],
                             event['context'])

        response = {
          'statusCode': 200,
          'body': json.dumps(record)
        }
        return response

    except Exception as e:
        _raise(Exception, 'Message:' + str(e))
