#########################################################################
#
#	USAGE:	readMetrics(file, metricType, season)
#
#		Metric Types:
#			soi,
#			hours,
#			hourlyFull,hourlyTrunc,
#			freqNight,freqDay,
#			ambFull,ambTrunc,
#			contourL90,contourL50,contourL05,contourLNAT,
#			pAud
#
#		Seasons:
#			Summer
#			Fall
#			Winter
#			Spring
#
#	OUTPUT:	List object
#		
#		[object]$n = sample size for metric
#		[object]$data = data.frame containing metric info
#
#	ABOUT:	Written by Damon Joyce (damon_joyce@nps.gov)
#			2013.01.24

###: Update 09/14/2023. Erik Meyer added read metrics functions for created listening lab data summaries using metric Type (LLDetail, LLCat, SPLATdet, SPLATCat, SPLATecs,SPLATels,SPLTnfi)
#########################################################################

#if(!exists(readMetrics, mode="function")) source("readMetrics.r")

readMetrics <- function(fileName, metricType, season)
{
	fileData <- scan(fileName, what="character", sep='\n', blank.lines.skip = F, quiet=T)
	blankLines <- grep("^$",fileData)
	versionTemp <- fileData[grep("###",fileData)]
	if(length(versionTemp) > 0)
	{
		mVersion <- as.numeric(strsplit(versionTemp,"V")[[1]][2])
		
		switch(metricType,
			soi = 
			{	
				return(gsub("Source of Interest: ","",fileData[grep("Source of Interest: ",fileData)]))
			},
			hours =
			{
				return(c(as.numeric(gsub(".*:\\s(\\d{2}).*","\\1",fileData[grep("Day:",fileData)])),
					as.numeric(gsub(".*:\\s(\\d{2}).*","\\1",fileData[grep("Night:",fileData)]))))
			},
			hourlyFull = 
			{
				dataPos <- grep(paste("Median Hour(ly)? Metrics \\(dBA\\), ",season,sep=""),fileData)
				if(length(dataPos) == 0)
				{
					return(NULL)
				}else
				{
					secEnd <- blankLines[which(blankLines > dataPos)][1]
					secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
					titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
					nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
					
					return(list(n=nSamples,data=t(read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
						sep='\t', na.strings=c("--.-","-888.0")))))
				}
			},
			hourlyTrunc = 
			{
				dataPos <- grep(paste("Median Hour(ly)? Metrics \\(dBT\\), ",season,sep=""),fileData)
				if(length(dataPos) == 0)
				{
					return(NULL)
				}else
				{
					secEnd <- blankLines[which(blankLines > dataPos)][1]
					secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
					titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
					nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
					
					return(list(n=nSamples,data=t(read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
						sep='\t', na.strings=c("--.-","-888.0")))))
				}
			},
			freqNight = 
			{
				dataPos <- grep(paste("Median Nighttime Frequency Metrics \\(dB\\), ",season,sep=""),fileData)
				if(length(dataPos) == 0)
				{
					return(NULL)
				}else
				{
					secEnd <- blankLines[which(blankLines > dataPos)][1]
					secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
					titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
					nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
					
					return(list(n=nSamples,data=t(read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
						sep='\t', na.strings=c("--.-","-888.0")))))
				}
			},
			freqDay = 
			{
				dataPos <- grep(paste("Median Daytime Frequency Metrics \\(dB\\), ",season,sep=""),fileData)
				if(length(dataPos) == 0)
				{
					return(NULL)
				}else
				{
					secEnd <- blankLines[which(blankLines > dataPos)][1]
					secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
					titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
					nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
					
					return(list(n=nSamples,data=t(read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
						sep='\t', na.strings=c("--.-","-888.0")))))
				}
			},
			ambFull = 
			{
				dataPos <- grep(paste("Ambient \\(dBA\\), ",season,sep=""),fileData)
				if(length(dataPos) == 0)
				{
					return(NULL)
				}else
				{
					secEnd <- blankLines[which(blankLines > dataPos)][1]
					secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
					titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
					nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
					
					return(list(n=nSamples,data=read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
						sep='\t', na.strings=c("--.-","-888.0"))))
				}
			},
			ambTrunc = 
			{
				dataPos <- grep(paste("Ambient \\(dBT\\), ",season,sep=""),fileData)
				if(length(dataPos) == 0)
				{
					return(NULL)
				}else
				{
					secEnd <- blankLines[which(blankLines > dataPos)][1]
					secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
					titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
					nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
					
					return(list(n=nSamples,data=read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
						sep='\t', na.strings=c("--.-","-888.0"))))
				}
			},
			timeAbove = 
      {
        dataPos <- grep(paste("Time Above \\(%\\), ",season,sep=""),fileData)[1]
        if(length(dataPos) == 0)
        {
          return(NULL)
        }else
        {
          secEnd <- blankLines[which(blankLines > dataPos)][1]
          secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
          titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
          nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
          
          return(list(n=nSamples,data=read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
                                                 sep='\t', na.strings=c("--.-","-888.0"), colClasses=c("character",rep("numeric",4)))))
        }
      },
      timeAboveT = 
      {
        dataPos <- grep(paste("Time Above \\(%\\), ",season,sep=""),fileData)[1]+5
        if(length(dataPos) == 0)
        {
          return(NULL)
        }else
        {
          secEnd <- blankLines[which(blankLines > dataPos)][1]
          secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
          titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
          nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
          
          return(list(n=nSamples,data=read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
                                                 sep='\t', na.strings=c("--.-","-888.0"))))
        }
      },
			contourL90 = 
			{
				dataPos <- grep(paste("L90 Contour Data \\(dB\\), ",season,sep=""),fileData)
				if(length(dataPos) == 0)
				{
					return(NULL)
				}else
				{
					secEnd <- blankLines[which(blankLines > dataPos)][1]
					secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
					titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
					nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
					
					return(list(n=nSamples,data=read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
						colClasses = c("character",rep("numeric",24)), sep='\t', na.strings=c("--.-","-888.0"))))
				}
			},
			contourL50 = 
			{
				dataPos <- grep(paste("L50 Contour Data \\(dB\\), ",season,sep=""),fileData)
				if(length(dataPos) == 0)
				{
					return(NULL)
				}else
				{
					secEnd <- blankLines[which(blankLines > dataPos)][1]
					secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
					titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
					nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
					
					return(list(n=nSamples,data=read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
						colClasses = c("character",rep("numeric",24)), sep='\t', na.strings=c("--.-","-888.0"))))
				}
			},
			contourL05 = 
			{
				dataPos <- grep(paste("L05 Contour Data \\(dB\\), ",season,sep=""),fileData)
				if(length(dataPos) == 0)
				{
					return(NULL)
				}else
				{
					secEnd <- blankLines[which(blankLines > dataPos)][1]
					secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
					titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
					nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
					
					return(list(n=nSamples,data=read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
						colClasses = c("character",rep("numeric",24)), sep='\t', na.strings=c("--.-","-888.0"))))
				}
			},
			contourLNAT = 
			{
				dataPos <- grep(paste("Lnat Contour Data \\(dB\\), ",season,sep=""),fileData)
				if(length(dataPos) == 0)
				{
					return(NULL)
				}else
				{
					secEnd <- blankLines[which(blankLines > dataPos)][1]
					secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
					titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
					nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
					
					return(list(n=nSamples,data=read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
						colClasses = c("character",rep("numeric",24)), sep='\t', na.strings=c("--.-","-888.0"))))
				}
			},
			LLDetail = 
			  {
			    ##for detailed summary of listening center files
			        dataPos <- grep(paste("Listening Center Detailed Event Audibility \\(%\\), ",season,sep=""),fileData)
			        if(length(dataPos) == 0)
			        {
			          return(NULL)
			        }else
			        {
			          secEnd <- blankLines[which(blankLines > dataPos)][1]
			          secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
			          titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
			          nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
			          
			          return(list(n=nSamples,data=(read.table(fileName, skip = dataPos, nrows = secLen, header=T, sep='\t', na.strings=c("--.-","-888.0")))))
			       }
			    },
			LLCat = 
			  {
			    ##for detailed summary of listening center files
			    dataPos <- grep(paste("Listening Center Categorical Event Audibility, ",season,sep=""),fileData)
			    if(length(dataPos) == 0)
			    {
			      return(NULL)
			    }else
			    {
			      secEnd <- blankLines[which(blankLines > dataPos)][1]
			      secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
			      titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
			      nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
			      
			      return(list(n=nSamples,data=(read.table(fileName, skip = dataPos, nrows = secLen, header=T, sep='\t', na.strings=c("--.-","-888.0")))))
			    }
			  },
			SPLATDet = 
			  {
			    ##for detailed summary of listening center files
			    dataPos <- grep(paste("SPLAT Detailed Event Audibility \\(%\\), ",season,sep=""),fileData)
			    if(length(dataPos) == 0)
			    {
			      return(NULL)
			    }else
			    {
			      secEnd <- blankLines[which(blankLines > dataPos)][1]
			      secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
			      titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
			      nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
			      
			      return(list(n=nSamples,data=(read.table(fileName, skip = dataPos, nrows = secLen, header=T, sep='\t', na.strings=c("--.-","-888.0")))))
			    }
			  },
			SPLATCat = 
			  {
			    ##for categorical summary of listening center files
			    dataPos <- grep(paste("SPLAT Categorical Event Audibility \\(%\\), ",season,sep=""),fileData)
			    if(length(dataPos) == 0)
			    {
			      return(NULL)
			    }else
			    {
			      secEnd <- blankLines[which(blankLines > dataPos)][1]
			      secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
			      titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
			      nSamples <- as.numeric(gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo))
			      
			      return(list(n=nSamples,data=(read.table(fileName, skip = dataPos, nrows = secLen, header=T, sep='\t', na.strings=c("--.-","-888.0")))))
			    }
			  },
			SPLATecs={
			  ## SPLAT average event counts per source, rows = Day/Night/24hr, columns = Source IDs
			  dataPos <- grep(paste("SPLAT Detailed Average Event Counts, ",season,sep=""),fileData)
			  if(length(dataPos) == 0)
			  {
			    return(NULL)
			  }else
			  {
			    secEnd <- blankLines[which(blankLines > dataPos)][1]
			    secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
			    titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
			    nSamples <- as.numeric(gsub(".*n\\s*=\\s*(\\d+).*","\\1",titleInfo))
			    
			    return(list(n=nSamples,data=read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
			                                           sep='\t', na.strings=c("--.-","-888.0"))))
			  }
			},
			SPLATels={
			  ## SPLAT average event lengths (sec) per source, rows = Day/Night/24hr, columns = Source IDs
			  dataPos <- grep(paste("SPLAT Detailed Average Event Lengths \\(sec\\), ",season,sep=""),fileData)
			  if(length(dataPos) == 0)
			  {
			    return(NULL)
			  }else
			  {
			    secEnd <- blankLines[which(blankLines > dataPos)][1]
			    secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
			    titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
			    nSamples <- as.numeric(gsub(".*n\\s*=\\s*(\\d+).*","\\1",titleInfo))
			    
			    return(list(n=nSamples,data=read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
			                                           sep='\t', na.strings=c("--.-","-888.0"))))
			  }
			},
			SPLATnfi={
			  ## SPLAT noise-free interval duration (sec), rows = 90%/50%/10%/Mean, columns = hour
			  dataPos <- grep(paste("SPLAT Noise Free Interval \\(sec\\), ",season,sep=""),fileData)
			  if(length(dataPos) == 0)
			  {
			    return(NULL)
			  }else
			  {
			    secEnd <- blankLines[which(blankLines > dataPos)][1]
			    secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
			    titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
			    nSamples <- as.numeric(gsub(".*n\\s*=\\s*(\\d+).*","\\1",titleInfo))
			    
			    return(list(n=nSamples,data=read.table(fileName, skip = dataPos, nrows = secLen, header=T, row.names=1,
			                                           colClasses = c("character",rep("numeric",24)), sep='\t', na.strings=c("--.-","-888.0"))))
			  }
			},
			pAud =
			{
				dataPos <- grep(paste("Time Audible \\(%\\), ",season,sep=""),fileData)
				if(length(dataPos) == 0)
				{
					return(NULL)
				}else
				{
					secEnd <- blankLines[which(blankLines > dataPos)][1]
					secLen <- secEnd - dataPos - 2	#-2 to account for header line, and the final blank line
					titleInfo <- scan(fileName, skip = dataPos - 1, sep = "!", n = 1, what = "character")
					nSamples <- gsub(".*=\\s(\\d+)hr.*","\\1",titleInfo)
					if(grepl("unknown",nSamples)) nSamples <- NA
					nSamples <- as.numeric(nSamples)
					
					return(list(n=nSamples,data=t(read.table(fileName, skip = dataPos, nrows = secLen, header=F, row.names=1,
						sep='\t', na.strings=c("--.-","-888.0")))))
				}
			}
		)
	}else return(NULL)
}

