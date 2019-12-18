
import os
import json
import uuid
import time
import requests


BASE_URL = os.environ['AGW_ENDPOINT_URL']


def _raise(exception, error):
    raise exception(error)


def get_headers():
    """Return headers to make API call"""
    headers = {'Content-type': 'application/json'}
    if os.environ.get('AWG_KEY'):
        headers.update({'x-api-key': os.environ['AWG_KEY']})
    return headers


def random_string(prefix="", postfix="", length=8):
    """Random string of hex chars"""
    if length > 32:
        _raise(ValueError, "Max length 32")
    return f"{prefix}{uuid.uuid4().hex[:length]}{postfix}"


def api_response(response, validate):
    """Structure response output and (optional) validation"""
    output = 'Response: ' \
        + str(response.status_code) + '\n' \
        + 'Output:\n' \
        + json.dumps(json.loads(response.text), indent=4, default=str)

    if validate and response.status_code not in accepted_codes:
        _raise(ValueError, output)
    return output


def api_post(data, path, accepted_codes=[200, 201, 202], validate=False):
    """Post to API gatewate and return result as a string
    Optional validate, stops processing on bad response code"""
    url = '/'.join([BASE_URL, path])
    response = requests.post(
        url,
        data=json.dumps(data),
        headers=get_headers()
    )
    return api_response(response, validate)


#def api_delete(path, id, validate=False):
#    """Api call to delete a record"""
#
#    url = '/'.join([BASE_URL, STAGE, path, str(id)])
#    print( url )
#    response = requests.delete(url,
#        headers=get_headers())
#    return api_response(response, validate)


def test_post_message(validate=False):
    """Configure input items for API call"""
    data = {
        "UserId": random_string(prefix="user-"),
        "PostUrl": random_string(prefix="https://", postfix=".com", length=32),
        "Tags": list(map(''.join, zip(*[iter(random_string(length=24))]*8)))
    }
    response = api_post(data, "posts", validate=validate)
    print(response)


if __name__ == '__main__':
    validate = False

    for _ in range(10):
        test_post_message(validate=validate)
    #print("Verify if records are in Dynamo ... delete start in 3 seconds")
