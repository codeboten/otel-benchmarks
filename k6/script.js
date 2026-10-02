import http from 'k6/http';

const RATE = parseInt(__ENV.RATE || '1000', 10);
const DURATION = __ENV.DURATION || '240s';
const PREALLOCATED_VUS = parseInt(__ENV.PREALLOCATED_VUS || '100', 10);
const MAX_VUS = parseInt(__ENV.MAX_VUS || '400', 10);
const TARGET_URL = __ENV.TARGET_URL;

export const options = {
    discardResponseBodies: true,
    summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(50)', 'p(90)', 'p(95)', 'p(99)'],
    scenarios: {
        constant_load: {
            executor: 'constant-arrival-rate',
            rate: RATE,
            timeUnit: '1s',
            duration: DURATION,
            preAllocatedVUs: PREALLOCATED_VUS,
            maxVUs: MAX_VUS,
        },
    },
};

export default function () {
    http.get(TARGET_URL);
}
