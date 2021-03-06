package com.example.project2_server.di

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase

class ShopDB {
    lateinit var sqliteDB: SQLiteDatabase

    fun insert(shop: Shop){
        val contentValues = ContentValues()
        contentValues.put("_id", shop._id)
        contentValues.put("name", shop.name)
        contentValues.put("type", shop.type)
        contentValues.put("contact", shop.contact)
        contentValues.put("address", shop.address)
        contentValues.put("businessHour", shop.businessHour)
        contentValues.put("detail", shop.detail)
        contentValues.put("imgUri", shop.imgUri)

        sqliteDB.insert("ShopDB", null, contentValues)
    }

    companion object {
        lateinit var INSTANCE: ShopDB
        lateinit var dbHelper: ShopDBHelper

        fun getInstance(context: Context): ShopDB {
            if (!this::INSTANCE.isInitialized) {
                INSTANCE = ShopDB()

                // Local DB - SQLiteDB
                dbHelper = ShopDBHelper(context, "ShopDB.db", null, 1)
                INSTANCE.sqliteDB = dbHelper.writableDatabase
            }
            return INSTANCE
        }
        fun initInstance(context: Context): ShopDB {
            dbHelper.onUpgrade(INSTANCE.sqliteDB, 1, 1)
            return INSTANCE
        }
    }
}