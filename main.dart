import 'dart:convert';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:provider/provider.dart';
import 'package:fl_chart/fl_chart.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => MqttService(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Home ESP32',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomeScreen(),
    );
  }
}

class MqttService extends ChangeNotifier {
  final String server = 'kebnekaise.lmq.cloudamqp.com';
  final String clientId = 'flutter_client_001';
  final String username = 'akwqowjr:akwqowjr';
  final String password = 'lpv1MJ1LmJz0mX48OFZw4xkMwj23bYBE';
  late MqttServerClient client;

  // Device state
  List<bool> relays = List.filled(8, false);
  bool motor = false;
  double temperature = 0;
  double humidity = 0;

  // History for graph
  List<Map<String, double>> tempHistory = [];
  final int maxHistory = 50;

  MqttService() {
    client = MqttServerClient(server, clientId);
    client.logging(on: false);
    client.keepAlivePeriod = 20;
    client.port = 1883;
    client.onConnected = onConnected;
    client.onDisconnected = onDisconnected;
    client.onSubscribed = onSubscribed;
    client.onUnsubscribed = onUnsubscribed;
    client.onSubscribeFail = onSubscribeFail;
    client.pongCallback = pong;

    _connect();
  }

  void _connect() async {
    try {
      await client.connect(username, password);
    } catch (e) {
      log('MQTT connect failed: $e');
      client.disconnect();
    }
    client.updates?.listen(_processMessage);
  }

  void onConnected() {
    log('MQTT connected');
    // Subscribe to topics
    for (int i = 0; i < 8; i++) {
      client.subscribe('smart_kobani/device001/relay/$i/set', MqttQos.atMostOnce);
    }
    client.subscribe('smart_kobani/device001/motor/set', MqttQos.atMostOnce);
    client.subscribe('smart_kobani/device001/status', MqttQos.atMostOnce);
  }

  void onDisconnected() => log('MQTT disconnected');
  void onSubscribed(String topic) => log('Subscribed: $topic');
  void onSubscribeFail(String topic) => log('Subscribe fail: $topic');
  void onUnsubscribed(String? topic) => log('Unsubscribed: $topic');
  void pong() => log('Ping response received');

  void _processMessage(List<MqttReceivedMessage<MqttMessage>> event) {
    final recMess = event[0].payload as MqttPublishMessage;
    final payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
    final topic = event[0].topic;

    log('MQTT in [$topic] => $payload');

    if (topic.endsWith('/status')) {
      try {
        final doc = json.decode(payload);
        if (doc is Map) {
          if (doc.containsKey('t')) temperature = (doc['t'] as num).toDouble();
          if (doc.containsKey('h')) humidity = (doc['h'] as num).toDouble();
          // History
          addHistory(temperature, humidity);
        }
      } catch (e) {
        log('JSON parse error: $e');
      }
      notifyListeners();
      return;
    }

    // Relay control
    if (topic.contains('/relay/')) {
      final idx = int.parse(topic.split('/')[3]);
      relays[idx] = (payload == '1' || payload.toLowerCase() == 'on');
      notifyListeners();
      return;
    }

    // Motor control
    if (topic.endsWith('/motor/set')) {
      motor = (payload == '1' || payload.toLowerCase() == 'on');
      notifyListeners();
      return;
    }
  }

  void addHistory(double t, double h) {
    tempHistory.add({'t': t, 'h': h});
    if (tempHistory.length > maxHistory) tempHistory.removeAt(0);
  }

  void toggleRelay(int idx) {
    relays[idx] = !relays[idx];
    client.publishMessage(
      'smart_kobani/device001/relay/$idx/set',
      MqttQos.atMostOnce,
      relays[idx] ? Uint8List.fromList([49]) : Uint8List.fromList([48]),
    );
    notifyListeners();
  }

  void toggleMotor() {
    motor = !motor;
    client.publishMessage(
      'smart_kobani/device001/motor/set',
      MqttQos.atMostOnce,
      motor ? Uint8List.fromList([49]) : Uint8List.fromList([48]),
    );
    notifyListeners();
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mqtt = Provider.of<MqttService>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Smart Home ESP32')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Text('Temperature: ${mqtt.temperature.toStringAsFixed(1)} °C'),
            Text('Humidity: ${mqtt.humidity.toStringAsFixed(1)} %'),
            const SizedBox(height: 12),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: 8,
              itemBuilder: (context, idx) {
                return Card(
                  child: ListTile(
                    title: Text('Relay ${idx + 1}'),
                    trailing: Switch(
                      value: mqtt.relays[idx],
                      onChanged: (_) => mqtt.toggleRelay(idx),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                title: const Text('Motor'),
                trailing: Switch(
                  value: mqtt.motor,
                  onChanged: (_) => mqtt.toggleMotor(),
                ),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () {
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const GraphScreen()));
              },
              child: const Text('Show History Graph'),
            ),
          ],
        ),
      ),
    );
  }
}

class GraphScreen extends StatelessWidget {
  const GraphScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mqtt = Provider.of<MqttService>(context);
    final history = mqtt.tempHistory;

    List<FlSpot> tempSpots = [];
    List<FlSpot> humSpots = [];
    for (int i = 0; i < history.length; i++) {
      tempSpots.add(FlSpot(i.toDouble(), history[i]['t']!));
      humSpots.add(FlSpot(i.toDouble(), history[i]['h']!));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Temperature & Humidity History')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: LineChart(
          LineChartData(
            titlesData: FlTitlesData(
              leftTitles: AxisTitles(
                  sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
              bottomTitles: AxisTitles(
                  sideTitles: SideTitles(showTitles: false)),
            ),
            gridData: FlGridData(show: true),
            borderData: FlBorderData(show: true),
            lineBarsData: [
              LineChartBarData(
                spots: tempSpots,
                isCurved: true,
                color: Colors.red,
                barWidth: 3,
                dotData: FlDotData(show: false),
              ),
              LineChartBarData(
                spots: humSpots,
                isCurved: true,
                color: Colors.blue,
                barWidth: 3,
                dotData: FlDotData(show: false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
