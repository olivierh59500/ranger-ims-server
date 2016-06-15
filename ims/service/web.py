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
Incident Management System web interface.
"""

__all__ = [
    "WebMixIn",
]

from ..data.json import textFromJSON, incidentAsJSON
from ..store.istore import NoSuchIncidentError
from ..element.queue import DispatchQueuePage
from ..element.queue_template import DispatchQueueTemplatePage
from ..element.incident import IncidentPage
from ..element.incident_template import IncidentTemplatePage
from ..element.root import RootPage
from .http import fixedETag, HeaderName, ContentType
from .klein import route
from .urls import URLs
from .auth import Authorization
from .query import applyEditsFromQuery



class WebMixIn(object):
    """
    Mix-in for web interface.
    """

    #
    # Static content
    #

    @route(URLs.styleSheetURL.asText(), methods=("HEAD", "GET"))
    @fixedETag
    def styleSheetResource(self, request):
        return self.styleSheet(request, "style.css")


    @route(URLs.logoURL.asText(), methods=("HEAD", "GET"))
    @fixedETag
    def logoResource(self, request):
        request.setHeader(HeaderName.contentType.value, ContentType.PNG.value)
        return self.builtInResource(request, "logo.png")


    @route(URLs.imsJSURL.asText(), methods=("HEAD", "GET"))
    @fixedETag
    def imsJSResource(self, request):
        return self.javaScript(request, "ims.js")


    #
    # Web interface
    #

    @route(u"/", methods=("HEAD", "GET"))
    def rootResource(self, request):
        """
        Server root page.

        This redirects to the application root page.
        """
        return self.redirect(request, URLs.prefixURL)


    @route(URLs.prefixURL.asText(), methods=("HEAD", "GET"))
    @route(URLs.prefixURL.asText() + u"/", methods=("HEAD", "GET"))
    @fixedETag
    def applicationRootResource(self, request):
        """
        Application root page.
        """
        self.authenticateRequest(request)

        return RootPage(self)


    # Event root page; redirect to event dispatch queue

    @route(URLs.eventURL.asText(), methods=("HEAD", "GET"))
    @route(URLs.eventURL.asText() + u"/", methods=("HEAD", "GET"))
    def eventRootResource(self, request, event):
        """
        Event root page.

        This redirects to the event's dispatch queue page.
        """
        return self.redirect(request, URLs.viewDispatchQueueRelativeURL)


    @route(URLs.viewDispatchQueueURL.asText(), methods=("HEAD", "GET"))
    @route(URLs.viewDispatchQueueURL.asText() + u"/", methods=("HEAD", "GET"))
    @fixedETag
    def viewDispatchQueuePage(self, request, event):
        # FIXME: Not strictly required because the underlying data is protected.
        # But the error you get is stupid, so let's avoid that for now.
        self.authorizeRequest(request, event, Authorization.readIncidents)

        return DispatchQueuePage(self, event)


    @route(URLs.viewDispatchQueueTemplateURL.asText(), methods=("HEAD", "GET"))
    @fixedETag
    def viewDispatchQueueTemplatePage(self, request):
        self.authenticateRequest(request, optional=True)

        return DispatchQueueTemplatePage(self)


    @route(URLs.queueJSURL.asText(), methods=("HEAD", "GET"))
    @fixedETag
    def queueJSResource(self, request):
        return self.javaScript(request, "queue.js")


    @route(URLs.dispatchQueueDataURL.asText(), methods=("HEAD", "GET"))
    def dispatchQueueDataResource(self, request, event):
        self.authorizeRequest(request, event, Authorization.readIncidents)

        stream = self.buildJSONArray(
            textFromJSON(incidentAsJSON(incident)).encode("utf-8")
            for incident in self.storage.incidents(event)
        )

        return self.jsonStream(request, stream, None)


    @route(URLs.viewIncidentNumberURL.asText(), methods=("HEAD", "GET"))
    @fixedETag
    def viewIncidentPage(self, request, event, number):
        # FIXME: Not strictly required because the underlying data is protected.
        # But the error you get is stupid, so let's avoid that for now.
        self.authorizeRequest(request, event, Authorization.readIncidents)

        if number == u"new":
            number = None
        else:
            try:
                number = int(number)
            except ValueError:
                return self.notFoundResource(request)

        return IncidentPage(self, event, number)


    @route(URLs.viewIncidentNumberURL.asText(), methods=("POST",))
    def editIncidentPage(self, request, event, number):
        self.authorizeRequest(
            request, event,
            Authorization.readIncidents | Authorization.writeIncidents
        )

        try:
            applyEditsFromQuery(
                storage=self.storage,
                event=event,
                number=number,
                author=request.user.uid,
                request=request
            )
        except NoSuchIncidentError:
            return self.notFoundResource(request)

        return IncidentPage(self, event, number)


    @route(URLs.viewIncidentNumberTemplateURL.asText(), methods=("HEAD", "GET"))
    @fixedETag
    def viewIncidentNumberTemplatePage(self, request):
        self.authenticateRequest(request, optional=True)

        return IncidentTemplatePage(self)


    @route(URLs.incidentJSURL.asText(), methods=("HEAD", "GET"))
    @fixedETag
    def incidentJSResource(self, request):
        return self.javaScript(request, "incident.js")
