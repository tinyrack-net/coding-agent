/// Converts an exact rolling interval to an equivalent five-field cron.
String? everyMsToFiveFieldCron(int everyMs) {
  if (everyMs <= 0 || everyMs % 60000 != 0) return null;
  final minutes = everyMs ~/ 60000;
  if (minutes < 60 && 60 % minutes == 0) {
    return '*/$minutes * * * *';
  }
  if (minutes == 60) return '0 * * * *';
  if (minutes % 60 != 0) return null;
  final hours = minutes ~/ 60;
  if (hours < 24 && 24 % hours == 0) {
    return '0 */$hours * * *';
  }
  if (hours == 24) return '0 0 * * *';
  return null;
}
