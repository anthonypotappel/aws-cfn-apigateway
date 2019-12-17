#!/usr/bin/env python3

import sys
import json
import logging

import time
import boto3
import cfnresponse

client = boto3.client('dynamodb')

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _raise(exception, error):
    """Exception raiser for use in lambdas"""
    raise exception(error)


# return response if correct, or raise either KeyError or a ValueError
validate_response = \
    lambda r: r if r['ResponseMetadata']['HTTPStatusCode'] == 200 else _raise(ValueError, str(r))

get_list = lambda d, k: d[k] if isinstance(d.get(k), list) else []

attr_dict = lambda lst: {attr["AttributeName"]: attr["AttributeType"] for attr in lst}

def describe_table(tablename):
    """Return (True, table) if all are ACTIVE, else (False, table)"""
    table = validate_response(client.describe_table(TableName=tablename))['Table']
    status = set(
        [table['TableStatus']] \
        + [gsi['IndexStatus'] for gsi in get_list(table, 'GlobalSecondaryIndexes')]
    )
    return status == set(['ACTIVE']), table


def waiter_table(tablename, delay=5, rounds=300):
    """Wait until Table is ACTIVE"""
    for retry in range(rounds):
        active, table = describe_table(tablename)
        if active:
            return table
        logger.info(f"Waiting:{str(retry)}")
        time.sleep(delay)
    return {}


def update_gsi(action, payload):
    """Create Global Secondary Index"""
    tablename = payload['TableName']
    indexname = payload['IndexName']
    keyschema = payload["KeySchema"]
    projection = payload["Projection"]

    table = waiter_table(tablename)

    if not table:
        _raise('Table timeout')

    # Check if GSI is already created
    gsi_dict = {gsi['IndexName']: gsi for gsi in get_list(table, 'GlobalSecondaryIndexes')}

    extension = {}
    if action == 'Delete':
        if indexname not in gsi_dict:
            return {}
        # todo: add delete logic
        print('CONTINUE DELETE')
        #return {}
    elif action in ['Create', 'Update']:
        if indexname in gsi_dict:
            # todo: add compare logic, if unchanged then return OK
            # note: should allow provisioned capacity updates
            print('LETS DELETE')
            if payload.get('delete_on_update') is True:
                update_gsi('Delete', payload)
            else:
                _raise(ValueError, 'Cant Update')

        # on create only
        extension = {"KeySchema": keyschema, "Projection": projection}
        action = 'Create'

    Update = {action: {"IndexName": indexname}}
    Update[action].update(extension)

    # Compare current attributes with attributes to be added
    attributes = []

    if payload.get("AttributeDefinitions"):
        current_attr = attr_dict( table["AttributeDefinitions"] )
        new_attr = attr_dict(payload["AttributeDefinitions"])

        for key, value in current_attr.items():
            if key in new_attr:
                if action == 'Delete':
                    # dont keep
                    continue
                else:
                    # verify if there are no conflicts
                    if new_attr[key] != value:
                        _raise(ValueError, "Cant update attribute value")

            # attribute is from existing table -- keep
            attributes.append({"AttributeName": key, "AttributeType": value})

        if action != 'Delete':
            for key, value in new_attr.items():
                if key in current_attr:
                    # already got attribute
                    continue

                # append attribute
                attributes.append({"AttributeName": key, "AttributeType": value})


    print( json.dumps(table, indent=4, default=str))
    print("#################### UPDATE #################")
    print( tablename )
    print( indexname )
    print( keyschema )
    print( projection )

    print( json.dumps( Update, default=str ))
    print( json.dumps( attributes ) )

    try:
        print( " ADDING GSI: " + indexname )
        response = validate_response(client.update_table(
            TableName=tablename,
            AttributeDefinitions=attributes,
            GlobalSecondaryIndexUpdates=[Update]))
        print( json.dumps( response, indent=4, default=str) )
        table = waiter_table(tablename)

    except Exception as e:
        raise _raise(ValueError, str(e))

    return {}

def handler(event, context):
    """Called by Lambda"""
    try:
        valid_requests = ['Create', 'Update', 'Delete']
        if event['RequestType'] not in valid_requests:
            _raise(ValueError, f"RequestType not in: {str(valid_requests)}")

        cfnresponse.send(
            event,
            context,
            cfnresponse.SUCCESS,
            update_gsi(event['RequestType'], event['ResourceProperties']),
            event['LogicalResourceId']
        )
    except Exception as e:
        cfnresponse.send(event, context, "FAILED", {"Message": str(e)})

class AttrDict(dict):
    def __init__(self, *args, **kwargs):
        super(AttrDict, self).__init__(*args, **kwargs)
        self.__dict__ = self


def test_lambda():
    event = {
        "RequestType": "Create",
        "ServiceToken": "arn:aws:lambda:::function:FunctionXYZ",
        "ResponseURL": "https://dummy.amazonaws.com",
        "StackId": "arn:aws:cloudformation:::stack/",
        "RequestId": "abc-def-ghi-1234",
        "LogicalResourceId": "FunctionXYZ",
        "ResourceType": "Custom::FunctionXYZ",
        "ResourceProperties": {
            "TableName": "Cfn-demo-stack-master-latest-Application-ApiGateway-1TVGZVRFKE9KR-UserTable-KDCO6Z6O4E2R",
            "IndexName": "Tag1",
            "AttributeDefinitions": [
                {
                    "AttributeName": "Tag1",
                    "AttributeType": "S"
                }
            ],
            "KeySchema": [
                {
                    "AttributeName": "Tag1",
                    "KeyType": "HASH"
                },
                {
                    "AttributeName": "EventTime",
                    "KeyType": "RANGE"
                }
            ],
            "Projection": {
                "ProjectionType": "INCLUDE",
                "NonKeyAttributes": [
                    "Message"
                ]
            },
            "delete_on_update": True
        }
    }

    context = AttrDict({
        "log_stream_name": "dummylog"
    })

    try:
        handler(event, context)
    except Exception as e:
        logger.info(e)
        pass

if __name__ == '__main__':
    sys.exit(test_lambda())
