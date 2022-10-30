import json
import random
from datetime import datetime
from pathlib import Path
from statistics import mean
import time

import flask
import sqlalchemy
import yaml
from flask import Flask, request
from google.cloud.sql.connector import Connector
from google.cloud.sqlcommenter.sqlalchemy.executor import BeforeExecuteFactory
from opentelemetry import trace
from opentelemetry.exporter.zipkin.proto.http import ZipkinExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
# https://opentelemetry.io/docs/instrumentation/python/getting-started/#configure-your-http-propagator-b3-baggage
from opentelemetry.propagate import set_global_textmap
from opentelemetry.propagators.b3 import B3MultiFormat
from opentelemetry.sdk.resources import SERVICE_NAME, Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import (BatchSpanProcessor, ConsoleSpanExporter)
from sqlalchemy import (Column, Float, Integer, Numeric, Sequence, String, create_engine, event)
from sqlalchemy.orm import declarative_base, sessionmaker

set_global_textmap(B3MultiFormat())

resource = Resource(attributes={
    SERVICE_NAME: "data-service"
})

zipkin_exporter = ZipkinExporter(endpoint="http://localhost:9411/api/v2/spans")

provider = TracerProvider(resource=resource)
provider.add_span_processor(BatchSpanProcessor(zipkin_exporter))

# https://cloud.google.com/trace/docs/setup/python-ot
# from opentelemetry import trace
# from opentelemetry.exporter.cloud_trace import CloudTraceSpanExporter
# from opentelemetry.sdk.trace import TracerProvider
# from opentelemetry.sdk.trace.export import BatchSpanProcessor
# from opentelemetry.trace import Link

# provider.add_span_processor(BatchSpanProcessor(CloudTraceSpanExporter()))

"""
The local Zipkin http exporter has a dependency issue with the CloudTraceSpanExporter :-/

$ pip install opentelemetry-exporter-zipkin-proto-http

...

Installing collected packages: protobuf, opentelemetry-exporter-zipkin-proto-http
  Attempting uninstall: protobuf
    Found existing installation: protobuf 4.21.9
    Uninstalling protobuf-4.21.9:
      Successfully uninstalled protobuf-4.21.9
ERROR: pip's dependency resolver does not currently take into account all the packages that are installed. This behaviour is the source of the following dependency conflicts.
grpcio-status 1.50.0 requires protobuf>=4.21.6, but you have protobuf 3.20.3 which is incompatible.
Successfully installed opentelemetry-exporter-zipkin-proto-http-1.13.0 protobuf-3.20.3
"""

trace.set_tracer_provider(provider)

# https://github.com/google/sqlcommenter/blob/master/python/sqlcommenter-python/README.md

# https://github.com/GoogleCloudPlatform/cloud-sql-python-connector/blob/main/tests/system/test_pg8000_connection.py#L30-L42

def make_engine(settings):
    def make_creator():
        connector = Connector()
        return connector.connect(
                    settings['gcp_host'],
                    'pg8000',
                    user=settings['gcp_user'],
                    password=settings['gcp_password'],
                    db='postgres')

    pool = sqlalchemy.create_engine('postgresql+pg8000://', creator=make_creator)
    pool.dialect.description_encoding = None
    return pool

Base = declarative_base()

class Mapping(Base):
    __tablename__ = 'mapping'
    id = Column(Integer, Sequence('mapping_id_seq'), primary_key=True)
    value = Column(Float())

    def __repr__(self):
        return "<Mapping(id='%s', value='%f')>" % (self.id, self.value,)



engine = make_engine(yaml.load(Path(__file__).parent.joinpath('settings.yaml').open(), Loader=yaml.Loader))

listener = BeforeExecuteFactory(
    with_db_driver=True,
    with_db_framework=True,
    with_opentelemetry=True,
)
sqlalchemy.event.listen(engine, 'before_cursor_execute', listener, retval=True)

if False:
    try:
        Base.metadata.drop_all(bind=engine, tables=[Mapping.__table__])
    except:
        pass

Base.metadata.create_all(engine)

Session = sessionmaker(bind=engine)
session = Session()

if False:
    vals = [random.uniform(0.0, 100.0) for _ in range(1000)]
    objects = [Mapping(value=x) for x in vals]
    session.bulk_save_objects(objects)
    session.commit()

def request_hook(span, environ):
    print('request_hook', span, environ)
    # if span and span.is_recording():
    #     span.set_attribute("custom_user_attribute_from_request_hook", "some-value")

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app, request_hook=request_hook)

@app.route('/')
def index():
    return 'Flask server is up.'

@app.route('/data/<name>')
def data(name):
    tracer = trace.get_tracer(__name__)

    with tracer.start_as_current_span('configure') as span:
        # print(request.headers)
        span.set_attribute('data-service.name', name) # not sanitised
        time.sleep(0.1)

    with tracer.start_as_current_span('query GCP'):
        ms = session.query(Mapping).order_by(Mapping.id)
        m  = mean([m.value for m in ms])
        return ('%.2f' % (m,))

if __name__ == '__main__':
    # https://github.com/open-telemetry/opentelemetry-python-contrib/issues/546
    app.run(host='localhost', port=8080, threaded=True, debug=True, use_reloader=False)
