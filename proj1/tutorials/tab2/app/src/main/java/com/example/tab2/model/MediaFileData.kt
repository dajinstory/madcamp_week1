package com.example.tab2.model

import android.net.Uri
import java.util.*

data class MediaFileData(
    val id:Long,
    val dateTaken: Date,
    val displayName: String,
    val uri: Uri
    )

