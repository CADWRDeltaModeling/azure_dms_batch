# requirements:
# pip install opentelemetry-api
# pip install opentelemetry-sdk
# pip install azure-monitor-opentelemetry-exporter
# pip install psutil
# %%
from opentelemetry import metrics
from opentelemetry.sdk.metrics import MeterProvider
from azure.monitor.opentelemetry.exporter import AzureMonitorMetricExporter

# from opentelemetry.sdk.metrics.export.controller import PushController

from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader

import psutil

# get the instrumentation key from env var
import os

#!AZINSIGHTS_CONNECTION_STRING=InstrumentationKey=xxxxx-xxxx-xxxx-xxxx-xxxxx
connection_string = os.environ.get("AZINSIGHTS_CONNECTION_STRING")
if not connection_string:
    connection_string = "InstrumentationKey=c54d7d8d-880e-47ba-b5ae-150dbaf351c5;IngestionEndpoint=https://eastus-8.in.applicationinsights.azure.com/;LiveEndpoint=https://eastus.livediagnostics.monitor.azure.com/;ApplicationId=082c06d3-1fe4-4a63-a1bc-9ff2cf8f31f5"
# Set the exporter
exporter = AzureMonitorMetricExporter(connection_string=f"{connection_string}")
reader = PeriodicExportingMetricReader(exporter, export_interval_millis=5000)
metrics.set_meter_provider(MeterProvider(metric_readers=[reader]))
# Create a namespaced meter
meter = metrics.get_meter_provider().get_meter(__name__)

# Create the metrics
cpu_metric = meter.create_gauge(
    "cpu_percent",
    description="CPU usage in percent",
    unit="1",
)

io_metric = meter.create_gauge(
    "io_counter",
    description="I/O operations",
    unit="1",
)

# Create labels
labels = {"vm": "nicky-wsl"}

# %%
# Send the metrics
import time

while True:
    time.sleep(10)
    cpu_percent = psutil.cpu_percent()
    cpu_metric.set(cpu_percent, labels)

    io_counter = (
        psutil.disk_io_counters().read_count + psutil.disk_io_counters().write_count
    )
    io_metric.set(io_counter, labels)


# %%
