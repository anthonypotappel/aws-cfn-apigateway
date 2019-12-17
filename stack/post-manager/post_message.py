
import time
import json
import boto3


def _raise(exception, error):
    raise exception(error)

try:
    dynamodb = boto3.resource('dynamodb')
except Exception as e:
    _raise(Exception, "Message:" + str(e))

value_get = lambda dictionary, key: dictionary[key] if key in dictionary else ""
max_length = lambda s, l: s if len(s[:l+1]) <= l else _raise(ValueError, f"String to long ({l})")


def post_message(payload, stagevars, context):
    table = dynamodb.Table(stagevars['DynamoDBTable'])

    record = {
      "UserId": max_length(payload['UserId'], 128),
      "EventTime": int(time.time() * 10**3),
      "SourceIP": max_length(value_get(context, 'source-ip'), 39),
      "UserAgent": max_length(value_get(context, 'user-agent'), 512),
      "PostUrl": max_length(payload['PostUrl'], 2048)
    }

    optional_items = {
        'ImageUrl': 2048,
        'Description': 2048
    }

    for key, length in optional_items.items():
        if not isinstance(payload.get(key), str):
            continue
        record.update({key: max_length(payload[key], length)}

    # add max 3 tags to item
    if isinstance(payload.get('Tags'), list):
      record.update({
        f"Tag{str(index)}": max_length(str(value[:129]), 128)
        for index, value in enumerate(payload['Tags'][0:3])
      })

    table.put_item(Item=record)
    return record

def handler(event,_):
    try:
        record = post_message(
            event['body-json'],
            event['stage-variables'],
            event['context']
        )

        response = {
          'statusCode': 200,
          'body': json.dumps(record)
        }
        return response

    except Exception as e:
        _raise(Exception, 'Message:' + str(e))
