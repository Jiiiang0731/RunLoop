import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../models/run_record.dart';

/// 本地 SQLite 持久化（跑步记录）。
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Future<Database> get database async {
    _db ??= await _init();
    return _db!;
  }

  Future<Database> _init() async {
    final String dir = await getDatabasesPath();
    final String path = p.join(dir, 'runloop.db');
    return openDatabase(
      path,
      version: 2,
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
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE run_records ADD COLUMN planned_route TEXT');
        }
      },
    );
  }

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
