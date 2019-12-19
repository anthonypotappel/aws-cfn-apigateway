
import os
import sys
import json
import uuid
import pytest
import random
import requests

from random import randint

from helper_functions import _raise
from helper_functions import loadenv
from helper_functions import random_string


@pytest.fixture
def headers():
    """Return headers to make API call"""
    headers = {'Content-type': 'application/json'}
    if os.environ.get('AWGKEY'):
        headers.update({'x-api-key': os.environ['AWGKEY']})
    return headers


@pytest.fixture
def taglist():
    tags = 10
    inputfile = f"{os.path.dirname(__file__)}/random_ipsum.txt"

    with open(inputfile, 'r') as stream:
        taglist = list(set(stream.read().strip().split('\n')))

    if len(taglist) < tags:
        _raise(ValueError, f"Max number of unique tags is:{len(tags)}")

    return taglist[:tags]


@pytest.fixture
def userpool():
    """Generate and return a list of users"""
    users = 10
    length = 8
    prefix = "user-"
    
    return [f"{prefix}{uuid.uuid4().hex[:length]}" for _ in range(users)]


#def api_delete(path, id, validate=False):
#    """Api call to delete a record"""
#
#    url = '/'.join([BASE_URL, STAGE, path, str(id)])
#    print( url )
#    response = requests.delete(url,
#        headers=get_headers())
#    return api_response(response, validate)

def post_message(headers, userpool, taglist):
    """Post single message"""

    data = {
        "UserId": userpool[randint(0,9)],
        "PostUrl": random_string(prefix="https://", postfix=".com", length=32),
        "Tags": taglist[0:3]
    }

    url = f"{os.environ['ENDPOINTURL']}/posts"

    response = requests.post(
        url,
        data=json.dumps(data),
        headers=headers
    )

    if response.status_code not in [200, 201, 202]:
        raise ValueError(f"Response {str(response.status_code)}:{response.text}")

    return


def test_post_message(headers, userpool, taglist):
    """Post a series of messages"""
    for _ in range(10):
        random.shuffle(taglist)
        post_message(headers, userpool, taglist)


loadenv()
