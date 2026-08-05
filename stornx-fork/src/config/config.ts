import * as dotenv from 'dotenv';

import { MetricsType } from '../enums.js';
import { logger } from './logger.js';

dotenv.config();

// required environment variables
const requiredEnvVariables: Array<string> = [
  'ENV',
  'APP_PORT',
  'CRONJOB_EXPRESSION',
  'PROMETHEUS_URL',
  'NAMESPACES',
  'METRICS_TYPE',
  'METRICS_UPPER_THRESHOLD',
  'METRICS_LOWER_THRESHOLD',
];

requiredEnvVariables.forEach((envVarName: string) => {
  if (!process.env[envVarName]) {
    logger.error(`Environment variable ${envVarName} is missing`);
  }
});

export const Config = {
  ENV: process.env.ENV ?? 'production',
  APP_PORT: process.env.APP_PORT ?? '3000',
  NAMESPACES: process.env.NAMESPACES?.split(',') ?? ['default'], // default is the default namespace
  CRONJOB_EXPRESSION: process.env.CRONJOB_EXPRESSION ?? '* * * * *',
  LOCALITY_LABELS_CRON: process.env.LOCALITY_LABELS_CRON ?? '* * * * *',
  metrics: {
    upperThreshold: process.env.METRICS_UPPER_THRESHOLD ? Number(process.env.METRICS_UPPER_THRESHOLD) / 100 : 0.8,
    lowerThreshold: process.env.METRICS_LOWER_THRESHOLD ? Number(process.env.METRICS_LOWER_THRESHOLD) / 100 : 0.2,
    type: (process.env.METRICS_TYPE as MetricsType) ?? MetricsType.MEMORY,
    /** Target P95 response time threshold in milliseconds. Nodes exceeding this are penalized. */
    responseTimeThreshold: process.env.RESPONSE_TIME_THRESHOLD ? Number(process.env.RESPONSE_TIME_THRESHOLD) : 100,
    /** P95 latency (ms) above which OptiScaler scales up regardless of CPU usage.
     * Separate from responseTimeThreshold above: that's a continuous traffic-split
     * scoring target (penalizes nodes gradually), this is a binary emergency gate —
     * reusing the 100ms target here would fire on every cron tick under normal load. */
    scaleLatencyThresholdMs: process.env.SCALE_LATENCY_THRESHOLD_MS
      ? Number(process.env.SCALE_LATENCY_THRESHOLD_MS)
      : 2000,
    weights: {
      CPU: process.env.CPU_WEIGHT ? Number(process.env.CPU_WEIGHT) : 0.5,
      Memory: process.env.MEMORY_WEIGHT ? Number(process.env.MEMORY_WEIGHT) : 0.5,
    },
  },
  prometheusUrl: process.env.PROMETHEUS_URL ?? 'http://prometheus.prometheus.svc.cluster.local:9090',
  /** Locality strings for the remote cluster's zones, comma-separated.
   * When set, OptiBalancer includes these localities in the distribute map so
   * Istio can route to and fail over to the remote cluster.
   * Format: "region/zone/*,region/zone/*"
   * Example: "eu-west-1/eu-west-1a/*,eu-west-1/eu-west-1b/*,eu-west-1/eu-west-1c/*"
   * Empty = no cross-cluster traffic (pure local distribute). */
  REMOTE_ZONES: process.env.REMOTE_ZONES
    ? process.env.REMOTE_ZONES.split(',').map((z) => z.trim()).filter(Boolean)
    : [],
  remoteSpillover: {
    /** Minimum % of traffic always sent to the remote cluster to keep its endpoints warm. */
    baselineWeight: process.env.REMOTE_BASELINE_WEIGHT ? Number(process.env.REMOTE_BASELINE_WEIGHT) : 5,
    /** Local avg CPU % (of limit) above which remote weight starts growing beyond baseline. */
    spilloverThreshold: process.env.SPILLOVER_THRESHOLD ? Number(process.env.SPILLOVER_THRESHOLD) : 50,
    /** Additional remote weight % gained per 1% of local CPU above spilloverThreshold. */
    spilloverScale: process.env.SPILLOVER_SCALE ? Number(process.env.SPILLOVER_SCALE) : 0.5,
    /** Hard cap on total remote weight %. Local zones always receive at least (100 - maxRemoteWeight)%. */
    maxRemoteWeight: process.env.MAX_REMOTE_WEIGHT ? Number(process.env.MAX_REMOTE_WEIGHT) : 40,
  },
  // OptiBalancer settings
  balancer: {
    /** Minimum L1 distance delta to trigger a DestinationRule update (lowered from 10 to 5) */
    minDeltaThreshold: process.env.BALANCER_MIN_DELTA ? Number(process.env.BALANCER_MIN_DELTA) : 5,
    /** Minimum step size for gradual traffic shift (used when delta is small) */
    minStepSize: process.env.BALANCER_MIN_STEP_SIZE ? Number(process.env.BALANCER_MIN_STEP_SIZE) : 5,
    /** Maximum step size for urgent traffic shifts (used when delta is large) */
    maxStepSize: process.env.BALANCER_MAX_STEP_SIZE ? Number(process.env.BALANCER_MAX_STEP_SIZE) : 20,
    /** Delta threshold at which max step size is applied (urgency scaling) */
    urgencyThreshold: process.env.BALANCER_URGENCY_THRESHOLD ? Number(process.env.BALANCER_URGENCY_THRESHOLD) : 50,
    /** Epsilon for convergence */
    epsilon: process.env.BALANCER_EPSILON ? Number(process.env.BALANCER_EPSILON) : 1,
  },
  // Fault tolerance settings
  faultTolerance: {
    /** Maximum number of zones to distribute replicas across for fault tolerance */
    maxZones: process.env.FT_MAX_ZONES ? Number(process.env.FT_MAX_ZONES) : 3,
  },
};
