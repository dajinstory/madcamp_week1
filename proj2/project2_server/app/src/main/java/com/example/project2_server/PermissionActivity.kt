package com.example.project2_server
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.widget.Toast
import androidx.annotation.RequiresApi
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.facebook.AccessToken
import com.facebook.CallbackManager
import com.facebook.login.widget.LoginButton

class PermissionActivity : AppCompatActivity() {
    companion object{
        const val TAG = "PERMISSION_ACTIVITY"
        const val PERMISSION_REQUEST_CODE = 1001
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val permissionList = arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
                Manifest.permission.READ_CONTACTS,
                Manifest.permission.WRITE_CONTACTS,
                Manifest.permission.CAMERA
        )

        if(checkPermissionList(permissionList).isEmpty()){
            Toast.makeText(this, "permission granted", Toast.LENGTH_SHORT).show()
            val fbIntent: Intent = Intent(this, FBActivity::class.java)
            startActivity(fbIntent)
            finish()
        }
        else{
            requestRuntimePermissions(permissionList)
        }
    }

    private fun checkPermissionList(permission: Array<String>): MutableList<String>{
        val notGrantedArray = mutableListOf<String>()

        permission.forEach {
            if (ContextCompat.checkSelfPermission(
                    this,
                    it
                ) != PackageManager.PERMISSION_GRANTED){
                notGrantedArray.add(it)
            }
        }
        return notGrantedArray
    }

    private fun requestRuntimePermissions(permissions: Array<String>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            // Don't need to request
            // It's supported in devices running VERSION_CODES.M or higher
            return
        }
        requestPermissions(
            permissions,
            PermissionActivity.PERMISSION_REQUEST_CODE
        )
    }

    @RequiresApi(Build.VERSION_CODES.M)
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>,
                                            grantResults: IntArray) {
        when (requestCode) {
            PermissionActivity.PERMISSION_REQUEST_CODE -> {
                if (grantResults.isEmpty()) {
                    throw RuntimeException("Empty permission result")
                }
                if (grantResults[0] == PackageManager.PERMISSION_GRANTED && grantResults[1] == PackageManager.PERMISSION_GRANTED) {
                    showDialog("Permission granted")
                    val fbIntent: Intent = Intent(this, FBActivity::class.java)
                    startActivity(fbIntent)
                    finish()
                } else {
                    if (shouldShowRequestPermissionRationale(
                            Manifest.permission.READ_EXTERNAL_STORAGE)) {
                        Log.d(PermissionActivity.TAG, "User declined, but i can still ask for more")
                        requestPermissions(
                            permissions,
                            PermissionActivity.PERMISSION_REQUEST_CODE
                        )
                    } else {
                        Log.d(PermissionActivity.TAG, "User declined and i can't ask")
                        showDialogToGetPermission()
                    }
                }
            }
        }
    }

    private fun showDialog(msg: String) {
        val builder = AlertDialog.Builder(this)
        builder.setTitle("Dialog")
            .setMessage(msg)
        val dialog = builder.create()
        dialog.show()
    }
    private fun showDialogToGetPermission() {
        val builder = AlertDialog.Builder(this)
        builder.setTitle("Permisisons request")
            .setMessage("We need the location permission for some reason. " +
                    "You need to move on Settings to grant some permissions")
        builder.setPositiveButton("OK") { _, _ ->
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        }
        builder.setNegativeButton("Later") { _, _ ->
            // ignore
        }
        val dialog = builder.create()
        dialog.show()
    }
}