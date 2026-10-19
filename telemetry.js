'use strict';

const endpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT?.replace(/\/+$/, '');
let sdk;

if (endpoint) {
  const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
  const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-http');
  const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
  const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');
  const { NodeSDK } = require('@opentelemetry/sdk-node');

  sdk = new NodeSDK({
    serviceName: process.env.OTEL_SERVICE_NAME || 'arvana-wear-api',
    traceExporter: new OTLPTraceExporter({ url: `${endpoint}/v1/traces` }),
    metricReader: new PeriodicExportingMetricReader({
      exporter: new OTLPMetricExporter({ url: `${endpoint}/v1/metrics` }),
      exportIntervalMillis: 15000,
    }),
    instrumentations: [getNodeAutoInstrumentations()],
  });

  sdk.start();
}

module.exports = () => sdk ? sdk.shutdown() : Promise.resolve();
