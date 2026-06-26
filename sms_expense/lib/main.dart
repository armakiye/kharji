import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:telephony/telephony.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ردیاب هزینه',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.dark(
          background: Color(0xFF0F0F14),
          surface: Color(0xFF1A1A24),
          primary: Color(0xFF7C6AF7),
          error: Color(0xFFF7706A),
        ),
        fontFamily: 'Vazirmatn',
        useMaterial3: true,
      ),
      home: const ExpenseHome(),
    );
  }
}

// ── Model ────────────────────────────────────────────────
class Expense {
  final int amount;
  final String desc;
  final String time;
  final String date;
  final String raw;

  Expense({
    required this.amount,
    required this.desc,
    required this.time,
    required this.date,
    required this.raw,
  });

  Map<String, dynamic> toJson() => {
    'amount': amount,
    'desc': desc,
    'time': time,
    'date': date,
    'raw': raw,
  };

  factory Expense.fromJson(Map<String, dynamic> j) => Expense(
    amount: j['amount'],
    desc: j['desc'],
    time: j['time'],
    date: j['date'],
    raw: j['raw'],
  );
}

// ── SMS Parser ────────────────────────────────────────────
class SmsParser {
  static final _bankSenders = [
    'bank', 'mellat', 'melli', 'saderat', 'tejarat',
    'parsian', 'pasargad', 'eghtesad', 'ansar', 'mehr',
    'bmi', 'bms', '۶۲۱۹', '۶۱۰۴', '۵۸۹۲', '۵۰۲۲',
    'sms', 'info',
  ];

  static bool isBankSms(SmsMessage sms) {
    final body = (sms.body ?? '').toLowerCase();
    final addr = (sms.address ?? '').toLowerCase();

    // Must contain برداشت or خرید or پرداخت
    final hasKeyword = body.contains('برداشت') ||
        body.contains('خرید') ||
        body.contains('پرداخت') ||
        body.contains('كسر') ||
        body.contains('بدهكار');

    if (!hasKeyword) return false;

    // Must have ریال or تومان
    final hasCurrency = body.contains('ريال') ||
        body.contains('ریال') ||
        body.contains('تومان');

    return hasCurrency;
  }

  static int? extractAmount(String text) {
    // Persian digit converter
    String normalized = text
        .replaceAllMapped(RegExp(r'[۰-۹]'), (m) {
          return String.fromCharCode(m.group(0)!.codeUnitAt(0) - 1728);
        })
        .replaceAll('٬', '')
        .replaceAll('،', '')
        .replaceAll(',', '');

    final patterns = [
      // برداشت 500000 ریال
      RegExp(r'(?:برداشت|خرید|پرداخت|كسر|بدهكار)[^\d]*(\d+)\s*(?:ریال|ريال|تومان)', caseSensitive: false),
      // مبلغ: 500000
      RegExp(r'مبلغ\s*:?\s*(\d+)\s*(?:ریال|ريال|تومان)?', caseSensitive: false),
      // 500,000 ریال (standalone)
      RegExp(r'(\d{4,})\s*(?:ریال|ريال|تومان)', caseSensitive: false),
      // هر عدد بالای ۴ رقم
      RegExp(r'(\d{5,})'),
    ];

    for (final p in patterns) {
      final m = p.firstMatch(normalized);
      if (m != null) {
        final num = int.tryParse(m.group(1)!.replaceAll(RegExp(r'\D'), ''));
        if (num != null && num > 1000) return num;
      }
    }
    return null;
  }

  static String extractDesc(String text) {
    final patterns = [
      RegExp(r'خرید از\s+([\u0600-\u06FF\w\s]{2,20})', caseSensitive: false),
      RegExp(r'پرداخت به\s+([\u0600-\u06FF\w\s]{2,20})', caseSensitive: false),
      RegExp(r'انتقال به\s+([\u0600-\u06FF\w\s]{2,20})', caseSensitive: false),
    ];

    for (final p in patterns) {
      final m = p.firstMatch(text);
      if (m != null) return m.group(1)!.trim();
    }

    // Extract meaningful Persian words
    final words = RegExp(r'[\u0600-\u06FF]{3,}')
        .allMatches(text)
        .map((m) => m.group(0)!)
        .where((w) => !['ریال','ريال','تومان','برداشت','موجودی','کارت','بانک',
          'حساب','انتقال','پرداخت','خرید','مبلغ','تاریخ','ساعت','از','به'].contains(w))
        .take(3)
        .join(' ');

    return words.isNotEmpty ? words : 'تراکنش بانکی';
  }
}

// ── Storage ────────────────────────────────────────────────
class Storage {
  static String todayKey() {
    final d = DateTime.now();
    return 'expenses_${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
  }

  static String dateKey(DateTime d) =>
      'expenses_${d.year}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';

  static Future<List<Expense>> loadToday() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(todayKey());
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => Expense.fromJson(e)).toList();
  }

  static Future<void> saveToday(List<Expense> expenses) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(todayKey(), jsonEncode(expenses.map((e) => e.toJson()).toList()));
  }

  static Future<Map<String, List<Expense>>> loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('expenses_')).toList();
    final today = todayKey();
    final result = <String, List<Expense>>{};
    for (final key in keys) {
      if (key == today) continue;
      final raw = prefs.getString(key);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        result[key.replaceFirst('expenses_', '')] =
            list.map((e) => Expense.fromJson(e)).toList();
      }
    }
    return result;
  }
}

// ── Main Screen ───────────────────────────────────────────
class ExpenseHome extends StatefulWidget {
  const ExpenseHome({super.key});

  @override
  State<ExpenseHome> createState() => _ExpenseHomeState();
}

class _ExpenseHomeState extends State<ExpenseHome> {
  final telephony = Telephony.instance;
  List<Expense> _expenses = [];
  bool _hasPermission = false;
  bool _loading = true;
  String _todayLabel = '';

  static const bg = Color(0xFF0F0F14);
  static const surface = Color(0xFF1A1A24);
  static const surface2 = Color(0xFF22222F);
  static const border = Color(0xFF2E2E40);
  static const accent = Color(0xFF7C6AF7);
  static const accentDim = Color(0x267C6AF7);
  static const red = Color(0xFFF7706A);
  static const green = Color(0xFF6AF7B8);
  static const muted = Color(0xFF7878A0);
  static const textColor = Color(0xFFE8E8F0);

  @override
  void initState() {
    super.initState();
    _todayLabel = _getPersianDate();
    _init();
  }

  String _getPersianDate() {
    // Simple Persian date display using Intl
    final now = DateTime.now();
    return '${now.year}/${now.month.toString().padLeft(2,'0')}/${now.day.toString().padLeft(2,'0')}';
  }

  Future<void> _init() async {
    await _requestPermission();
    await _loadExpenses();
    if (_hasPermission) {
      await _scanSms();
    }
    setState(() => _loading = false);
  }

  Future<void> _requestPermission() async {
    final status = await Permission.sms.request();
    setState(() => _hasPermission = status.isGranted);
  }

  Future<void> _loadExpenses() async {
    final list = await Storage.loadToday();
    setState(() => _expenses = list);
  }

  Future<void> _scanSms() async {
    try {
      final messages = await telephony.getInboxSms(
        columns: [SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE],
        filter: SmsFilter.where(SmsColumn.DATE)
            .greaterThan(
          DateTime.now()
              .copyWith(hour: 0, minute: 0, second: 0)
              .millisecondsSinceEpoch
              .toString(),
        ),
      );

      final existingRaws = _expenses.map((e) => e.raw).toSet();
      final newExpenses = <Expense>[];

      for (final sms in messages) {
        final body = sms.body ?? '';
        if (!SmsParser.isBankSms(sms)) continue;
        if (existingRaws.contains(body)) continue;

        final amount = SmsParser.extractAmount(body);
        if (amount == null) continue;

        final now = DateTime.fromMillisecondsSinceEpoch(sms.date ?? 0);
        final time =
            '${now.hour.toString().padLeft(2,'0')}:${now.minute.toString().padLeft(2,'0')}';

        newExpenses.add(Expense(
          amount: amount,
          desc: SmsParser.extractDesc(body),
          time: time,
          date: _getPersianDate(),
          raw: body,
        ));
      }

      if (newExpenses.isNotEmpty) {
        final updated = [..._expenses, ...newExpenses];
        await Storage.saveToday(updated);
        setState(() => _expenses = updated);
        _showSnack('${newExpenses.length} تراکنش جدید پیدا شد ✓');
      }
    } catch (e) {
      debugPrint('SMS scan error: $e');
    }
  }

  Future<void> _deleteExpense(int i) async {
    final updated = List<Expense>.from(_expenses)..removeAt(i);
    await Storage.saveToday(updated);
    setState(() => _expenses = updated);
  }

  void _copyReport() {
    if (_expenses.isEmpty) {
      _showSnack('هنوز هزینه‌ای ثبت نشده');
      return;
    }
    final total = _expenses.fold(0, (s, e) => s + e.amount);
    final lines = ['📊 گزارش هزینه — $_todayLabel', '─────────────────'];
    for (int i = 0; i < _expenses.length; i++) {
      final e = _expenses[i];
      lines.add('${i + 1}. [${e.time}]  ${e.desc}');
      lines.add('    ${_formatNum(e.amount)} ریال');
    }
    lines.add('─────────────────');
    lines.add('💰 جمع کل: ${_formatNum(total)} ریال');
    final text = lines.join('\n');
    Clipboard.setData(ClipboardData(text: text));
    _showSnack('گزارش کپی شد ✓');
  }

  void _shareReport() {
    if (_expenses.isEmpty) return;
    final total = _expenses.fold(0, (s, e) => s + e.amount);
    final lines = ['📊 گزارش هزینه — $_todayLabel', '─────────────────'];
    for (int i = 0; i < _expenses.length; i++) {
      final e = _expenses[i];
      lines.add('${i + 1}. [${e.time}]  ${e.desc}');
      lines.add('    ${_formatNum(e.amount)} ریال');
    }
    lines.add('─────────────────');
    lines.add('💰 جمع کل: ${_formatNum(total)} ریال');
    Share.share(lines.join('\n'));
  }

  String _formatNum(int n) =>
      NumberFormat('#,###').format(n);

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontFamily: 'Vazirmatn')),
        backgroundColor: surface2,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = _expenses.fold(0, (s, e) => s + e.amount);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: bg,
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: accent))
            : Column(
                children: [
                  _buildHeader(),
                  _buildTotalCard(total),
                  if (!_hasPermission) _buildPermissionBanner(),
                  Expanded(child: _buildList()),
                  _buildBottomBar(),
                ],
              ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 52, 20, 14),
      decoration: const BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('💳 ردیاب هزینه',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: textColor)),
              Text(_todayLabel,
                  style: const TextStyle(fontSize: 12, color: muted)),
            ],
          ),
          Row(
            children: [
              IconButton(
                onPressed: _scanSms,
                icon: const Icon(Icons.refresh, color: muted, size: 20),
                tooltip: 'اسکن مجدد',
              ),
              TextButton(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const HistoryScreen())),
                child: const Text('تاریخچه',
                    style: TextStyle(color: muted, fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTotalCard(int total) {
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        color: accentDim,
        border: Border.all(color: accent.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('جمع هزینه‌های امروز',
                  style: TextStyle(fontSize: 12, color: muted)),
              const SizedBox(height: 4),
              Text('${_formatNum(total)} ریال',
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w700, color: accent)),
            ],
          ),
          Column(
            children: [
              Text('${_expenses.length}',
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w700, color: textColor)),
              const Text('تراکنش',
                  style: TextStyle(fontSize: 12, color: muted)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionBanner() {
    return GestureDetector(
      onTap: _requestPermission,
      child: Container(
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: red.withOpacity(0.1),
          border: Border.all(color: red.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: red, size: 18),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'برای دسترسی خودکار به پیامک‌ها، روی اینجا بزن و مجوز بده',
                style: TextStyle(fontSize: 13, color: red),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    if (_expenses.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('📭', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            const Text(
              'هنوز تراکنشی ثبت نشده\nپیامک‌های بانکی امروز اسکن می‌شن',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: muted, height: 1.6),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: _scanSms,
              icon: const Icon(Icons.refresh, color: accent),
              label: const Text('اسکن مجدد', style: TextStyle(color: accent)),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      itemCount: _expenses.length,
      itemBuilder: (ctx, i) {
        final e = _expenses[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: surface,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: () => _deleteExpense(i),
                icon: const Icon(Icons.close, size: 16, color: muted),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.time,
                        style: const TextStyle(fontSize: 11, color: muted)),
                    const SizedBox(height: 2),
                    Text(e.desc,
                        style: const TextStyle(fontSize: 13, color: textColor),
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              Text('${_formatNum(e.amount)} ریال',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: red)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      decoration: const BoxDecoration(
        color: surface,
        border: Border(top: BorderSide(color: border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _copyReport,
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('کپی گزارش'),
              style: ElevatedButton.styleFrom(
                backgroundColor: surface2,
                foregroundColor: textColor,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: _shareReport,
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            child: const Icon(Icons.share, size: 20),
          ),
        ],
      ),
    );
  }
}

// ── History Screen ─────────────────────────────────────────
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  Map<String, List<Expense>> _history = {};
  bool _loading = true;

  static const bg = Color(0xFF0F0F14);
  static const surface = Color(0xFF1A1A24);
  static const surface2 = Color(0xFF22222F);
  static const border = Color(0xFF2E2E40);
  static const accent = Color(0xFF7C6AF7);
  static const red = Color(0xFFF7706A);
  static const muted = Color(0xFF7878A0);
  static const textColor = Color(0xFFE8E8F0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final h = await Storage.loadHistory();
    setState(() {
      _history = h;
      _loading = false;
    });
  }

  String _formatNum(int n) => NumberFormat('#,###').format(n);

  @override
  Widget build(BuildContext context) {
    final sortedKeys = _history.keys.toList()..sort((a, b) => b.compareTo(a));

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          title: const Text('📅 تاریخچه',
              style: TextStyle(color: textColor, fontFamily: 'Vazirmatn')),
          iconTheme: const IconThemeData(color: muted),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator(color: accent))
            : sortedKeys.isEmpty
                ? const Center(
                    child: Text('هنوز روزی آرشیو نشده',
                        style: TextStyle(color: muted, fontFamily: 'Vazirmatn')))
                : ListView.builder(
                    padding: const EdgeInsets.all(20),
                    itemCount: sortedKeys.length,
                    itemBuilder: (ctx, i) {
                      final date = sortedKeys[i];
                      final items = _history[date]!;
                      final total = items.fold(0, (s, e) => s + e.amount);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: surface,
                          border: Border.all(color: border),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('📅 $date',
                                style: const TextStyle(
                                    fontSize: 13, color: accent, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 10),
                            ...items.asMap().entries.map((entry) => Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text('[${entry.value.time}] ${entry.value.desc}',
                                          style: const TextStyle(fontSize: 12, color: muted)),
                                      Text('${_formatNum(entry.value.amount)} ریال',
                                          style: const TextStyle(fontSize: 12, color: textColor)),
                                    ],
                                  ),
                                )),
                            const Divider(color: border, height: 16),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('جمع: ${_formatNum(total)} ریال',
                                    style: const TextStyle(
                                        fontSize: 14, fontWeight: FontWeight.w700, color: red)),
                                TextButton(
                                  onPressed: () {
                                    final lines = ['📊 گزارش $date', '─────────────'];
                                    for (int j = 0; j < items.length; j++) {
                                      lines.add('${j+1}. [${items[j].time}] ${items[j].desc}');
                                      lines.add('    ${_formatNum(items[j].amount)} ریال');
                                    }
                                    lines.add('─────────────');
                                    lines.add('💰 جمع: ${_formatNum(total)} ریال');
                                    Clipboard.setData(ClipboardData(text: lines.join('\n')));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('کپی شد ✓')));
                                  },
                                  child: const Text('کپی', style: TextStyle(color: accent, fontSize: 12)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
