export function isPersonalRenumbering(from, to) {
  return /^0\.0\.\d+-main[0-9a-f]+\.pi\.(?:c)?[0-9a-f]+$/.test(from)
    && /^\d+\.\d+\.\d+-nightly\.\d{8}\.\d+\.personal\.[1-9]\d*$/.test(to);
}
