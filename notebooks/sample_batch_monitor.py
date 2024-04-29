# requirements: 
# pip install opentelemetry-api
# pip install opentelemetry-sdk
# pip install azure-monitor-opentelemetry-exporter
# pip install psutil

from opentelemetry import metrics
from opentelemetry.sdk.metrics import MeterProvider
from azure.monitor.opentelemetry.exporter import AzureMonitorMetricExporter
#from opentelemetry.sdk.metrics.export.controller import PushController

from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader

import psutil

# get the instrumentation key from env var
import os
instrumentation_key = os.environ.get('INSTRUMENTATION_KEY')
ingestion_endpoint = os.environ.get('INGESTION_ENDPOINT')
# Set the exporter
exporter = AzureMonitorMetricExporter(
    connection_string=f"InstrumentationKey={instrumentation_key};IngestionEndpoint={ingestion_endpoint}"
)
reader = PeriodicExportingMetricReader(exporter, export_interval_millis=5000)
metrics.set_meter_provider(MeterProvider(metric_readers=[reader]))
# Create a namespaced meter
meter = metrics.get_meter_provider().get_meter(__name__)

# Create the metrics
cpu_metric = meter.create_counter(
    "cpu_percent",
    description="CPU usage in percent",
    unit="1",
)

io_metric = meter.create_counter(
    "io_counter",
    description="I/O operations",
    unit="1",
)

# Create labels
labels = {"environment": "production"}


# Send the metrics
import time
while True:
    time.sleep(10)
    cpu_percent = psutil.cpu_percent()
    cpu_metric.add(cpu_percent, labels)

    io_counter = psutil.disk_io_counters().read_count + psutil.disk_io_counters().write_count
    io_metric.add(io_counter, labels)

