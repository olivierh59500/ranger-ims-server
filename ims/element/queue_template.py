##
# See the file COPYRIGHT for copyright information.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##

"""
Dispatch queue page template.
"""

__all__ = [
    "DispatchQueueTemplatePage",
]

from .base import Element



class DispatchQueueTemplatePage(Element):
    """
    Queue page template.
    """

    def __init__(self, service):
        Element.__init__(
            self, u"queue_template", service, title=u"Dispatch Queue"
        )
