import 'package:latlong2/latlong.dart';

class Endpoint {
  String apiUrl;
  String token;
  String cert;

  Endpoint({required this.apiUrl, required this.token, required this.cert});
}

LatLng latlngAtLoading = const LatLng(0, 0);
Endpoint? serverEndpoint;
String localeZone = "unset";

// Public CE build: upstream deployment credentials are intentionally absent.
// Keep a disabled endpoint so the app can compile without private secrets.
final Endpoint reflectorNorthAmerica =
    Endpoint(apiUrl: "unset", token: "", cert: "");

void selectEndpoint(LatLng latlng) {
  latlngAtLoading = latlng;
  if (latlngAtLoading.longitude > -180 &&
      latlngAtLoading.longitude < -50 &&
      latlngAtLoading.latitude > 13) {
    serverEndpoint = reflectorNorthAmerica;
    localeZone = "NA";
  } else {
    serverEndpoint = reflectorNorthAmerica;
  }
}
