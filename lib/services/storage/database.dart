import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../models/run_record.dart';

/// 本地 SQLite 持久化（跑步记录 + 规划路线）。
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Future<Database> get database async {
    _db ??= await _init();
    return _db!;
  }

  static const String _createPlannedRoutesTable = '''
    CREATE TABLE planned_routes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      created_at INTEGER NOT NULL,
      target_m REAL NOT NULL,
      seed INTEGER NOT NULL,
      distance_m REAL NOT NULL,
      payload TEXT NOT NULL
    )
  ''';

  Future<Database> _init() async {
    final String dir = await getDatabasesPath();
    final String path = p.join(dir, 'runloop.db');
    return openDatabase(
      path,
      version: 3,
      onCreate: (Database db, int version) async {
        await db.execute('''
          CREATE TABLE run_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_time INTEGER NOT NULL,
            end_time INTEGER,
            duration_s INTEGER NOT NULL,
            moving_s INTEGER NOT NULL,
            distance_m REAL NOT NULL,
            avg_pace REAL NOT NULL,
            track_points TEXT NOT NULL,
            planned_route TEXT,
            rpe INTEGER,
            note TEXT
          )
        ''');
        await db.execute(_createPlannedRoutesTable);
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE run_records ADD COLUMN planned_route TEXT');
        }
        if (oldVersion < 3) {
          await db.execute(_createPlannedRoutesTable);
        }
      },
    );
  }

  // ---------- 规划路线 ----------

  /// 保存一条规划路线（用户选择后、开始跑步前调用），返回本地 id。
  Future<int> savePlannedRoute({
    required double targetM,
    required int seed,
    required double distanceM,
    required String payload,
  }) async {
    final Database db = await database;
    return db.insert('planned_routes', <String, dynamic>{
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'target_m': targetM,
      'seed': seed,
      'distance_m': distanceM,
      'payload': payload,
    });
  }

  /// 读取最近保存的规划路线（用于断网/重开 App 后恢复）。
  Future<Map<String, dynamic>?> getLatestPlannedRoute() async {
    final Database db = await database;
    final List<Map<String, dynamic>> rows = await db.query(
      'planned_routes',
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, dynamic>?> getPlannedRoute(int id) async {
    final Database db = await database;
    final List<Map<String, dynamic>> rows = await db.query(
      'planned_routes',
      where: 'id = ?',
      whereArgs: <Object>[id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  // ---------- 跑步记录 ----------

  Future<int> insertRun(RunRecord record) async {
    final Database db = await database;
    return db.insert('run_records', record.toMap());
  }

  Future<void> updateRunMeta(int id, {int? rpe, String? note}) async {
    final Database db = await database;
    await db.update(
      'run_records',
      {'rpe': rpe, 'note': note},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<RunRecord>> getRuns() async {
    final Database db = await database;
    final List<Map<String, dynamic>> rows =
        await db.query('run_records', orderBy: 'start_time DESC');
    return rows.map((Map<String, dynamic> r) => RunRecord.fromMap(r)).toList();
  }

  Future<void> deleteRun(int id) async {
    final Database db = await database;
    await db.delete('run_records', where: 'id = ?', whereArgs: [id]);
  }
}
