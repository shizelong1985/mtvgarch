## --- tvgarch_class Structure --- ####

## --- When created:

# Slots (internal variables for use in methods - should only be set by pkg_code)

# tvgarch@tvObj                     -- initial tv object used to create the multiplicative object
# tvgarch@garchObj                  -- initial garch object used to create the multiplicative object
# tvgarch@value                  -- "numeric" - starting log-liklihood value
# tvgarch@e                      -- "numeric" - starting data set

# properties (external variables, visible to user)

# tvgarch$Estimated$value        -- scalar: log-liklihood value
# tvgarch$Estimated$tv
# tvgarch$Estimated$garch


## --- TV_CLASS Definition --- ####

tv <- setClass(Class = "tv_class",
               slots = c(st="numeric",g="numeric",delta0free="logical",nr.pars="integer", nr.transitions="integer",Tobs="integer",taylor.order="integer"),
               contains = c("namedList")
)

setMethod("initialize","tv_class",
          function(.Object,...){
            .Object <- callNextMethod(.Object,...)
            # Slots
            .Object@st <- c(NaN)
            .Object@g <- c(NaN)
            .Object@delta0free <- TRUE
            .Object@nr.pars <- as.integer(1)
            .Object@nr.transitions <- as.integer(0)
            .Object@Tobs <- as.integer(0)
            .Object@taylor.order <- as.integer(0)

            # Properties
            .Object$shape <- tvshape$delta0only
            .Object$speedopt <- speedopt$none
            .Object$delta0 <- 1.0
            .Object$pars <- matrix(NA,4,1)
            .Object$optimcontrol <- list(fnscale = -1, maxit = 1500, reltol = 1e-7)

            # Return:
            .Object
          })

setGeneric(name="tv",
           valueClass = "tv_class",
           signature = c("st","shape"),
           def = function(st,shape){

             # Validate shape:
             if(length(shape) > 1){
               if(any(shape == tvshape$delta0only)) stop("Invalid shape: delta0only / 0 is not a valid transition shape")
             }

             this <- new("tv_class")
             this$shape <- shape
             this@st <- st
             this@Tobs <- length(st)
             this@g <- rep(this$delta0,this@Tobs)

             if(shape[1] == tvshape$delta0only){
               this@nr.transitions <- as.integer(0)
               this$optimcontrol$ndeps <- c(1e-5)
               this$optimcontrol$parscale <- c(1)
             }else {
               this$speedopt <- speedopt$eta
               this@nr.transitions <- length(shape)
               # Create the starting Pars matrix
               this  <- .setInitialPars(this)
               rownames(this$pars) <- c("deltaN","speedN","locN1","locN2")
               this@nr.pars <- as.integer(length(this$pars[!is.na(this$pars)]) + 1)  # +1 for delta0
               this$optimcontrol$ndeps <- rep(1e-5,this@nr.pars)
               #TODO: Improve the parScale to better manage different Speed Options
               parScale <- rep(c(3,3,1,1),this@nr.transitions)
               # Tricky bit of 'maths' below to produce NA's in the NA locations  :P
               parScale <- parScale + (as.vector(this$pars) - as.vector(this$pars))
               this$optimcontrol$parscale <- c(3,parScale[!is.na(parScale)])

             }
             return(this)
           }
)

## --- Public TV Methods --- ####

## -- estimateTV(e,tv,ctrl) ####

setGeneric(name="estimateTV",
           valueClass = "tv_class",
           signature = c("e","tvObj","estimationControl"),
           def=function(e,tvObj,estimationControl){
             this <- tvObj
             this$Estimated <- list()
             if(is.null(this$Estimated$delta0)) this$Estimated$delta0 <- this$delta0

             if(!is.list(estimationControl)) estimationControl <- list()
             if(!is.null(estimationControl$calcSE)) calcSE <- estimationControl$calcSE else calcSE <- FALSE
             if(!is.null(estimationControl$verbose)) verbose <- estimationControl$verbose else verbose <- FALSE

             # Check for the simple case of just delta0 provided, no TV$pars
             if(this@nr.transitions == 0){
               if(this@delta0free){
                 this$Estimated$delta0 <- var(e)

                 this@nr.pars <- as.integer(1)
               } else {
                 this@nr.pars <- as.integer(0)
               }
               this@g <- rep(this$Estimated$delta0,this@Tobs)
               if(calcSE) this$Estimated$delta0_se <- NaN
               this$Estimated$pars <- c(NA,NA,NA,NA)
               this$Estimated$value <- sum(-0.5*log(2*pi) - 0.5*log(this@g) - (0.5*e^2)/this@g)
               this$Estimated$error <- FALSE
               return(this)
             }

             # Set verbose tracing:
             if (verbose) {
               this$optimcontrol$trace <- 10
               cat("\nEstimating TV object...\n")
             } else this$optimcontrol$trace <- 0

             # Set the Optimpars
             optimpars <- NULL
             parsVec <- as.vector(this$pars)
             parsVec <- parsVec[!is.na(parsVec)]

             if(this@delta0free){
               # Estimating a single TV_class object
               optimpars <- c(this$Estimated$delta0, parsVec)
             }else{
               # Estimating a TVGARCH_class object - (delta0 is fixed to the passed-in estimated value)
               optimpars <- parsVec
               this$optimcontrol$nDeps <- tail(this$optimcontrol$nDeps,this@nr.pars)
               this$optimcontrol$parscale <- tail(this$optimcontrol$nDeps,this@nr.pars)
             }

             # Now call optim:
             tmp <- NULL
             try(tmp <- optim(optimpars,loglik.tv.univar,gr=NULL,e,this,method="BFGS",control=this$optimcontrol,hessian=calcSE))

             ## --- Attach results of estimation to the object --- ##

             # An unhandled error could result in a NULL being returned by optim()
             if (is.null(tmp)) {
               this$Estimated$value <- -Inf
               this$Estimated$error <- TRUE
               warning("estimateTV() - optim failed and returned NULL. Check the optim controls & starting params")
               return(this)
             }
             if (tmp$convergence != 0) {
               this$Estimated$value <- -Inf
               this$Estimated$error <- TRUE
               this$Estimated$optimoutput <- tmp
               warning("estimateTV() - failed to converge. Check the optim controls & starting params")
               return(this)
             }

             this$Estimated$value <- tmp$value
             this$Estimated$error <- FALSE

             #Update the TV object parameters using optimised pars:
             if (this@delta0free){
               this$Estimated$delta0 <- as.numeric(tmp$par[1])
               this <- .estimatedParsToMatrix(this,tail(tmp$par,-1))
             } else{
               if (is.null(this$Estimated$delta0)) this$Estimated$delta0 <- this$delta0
               this <- .estimatedParsToMatrix(this,tmp$par)
             }
             colnames(this$Estimated$pars) <- paste("st" ,1:this@nr.transitions,sep = "")

             # Get the conditional variances
             this@g <- .calculate_g(this)

             # Calc the std errors
             this$Estimated$delta0_se <- NULL
             this$Estimated$se <- NULL

             if (calcSE) {
               this$Estimated$hessian <- round(tmp$hessian,5)
               stdErrors <- NULL
               try(stdErrors <- sqrt(-diag(qr.solve(tmp$hessian))))
               if(!is.null(stdErrors)){
                 parsVec <-  as.vector(this$pars)

                 if (this@delta0free){
                   this$Estimated$delta0_se <- stdErrors[1]
                   stdErrors <- tail(stdErrors,-1)
                 }

                 seIndex <- 1
                 for(n in seq_along(parsVec)){
                   if(!is.na(parsVec[n])) {
                     this$Estimated$se[n] <- stdErrors[seIndex]
                     seIndex <- seIndex + 1
                   } else this$Estimated$se[n] <- NaN
                 }
                 this$Estimated$se <- matrix(this$Estimated$se,nrow = 4)
                 colnames(this$Estimated$se) <- paste("se" ,1:this@nr.transitions,sep = "")
               }
             }
             if (verbose) this$Estimated$optimoutput <- tmp

             return(this)
           })

setMethod("estimateTV",signature = c("numeric","tv_class","missing"),
          function(e,tvObj){
            estControl <- list()
            estControl$calcSE <- FALSE
            estControl$verbose <- FALSE
            estControl$taylor.order <- as.integer(0)
            estimateTV(e,tvObj,estControl)
          })

## -- test.LM.TR2(e,tv) ####
setGeneric(name="test.LM.TR2",
           valueClass = "numeric",
           signature = c("e","tvObj"),
           def=function(e,tvObj){
             this <- tvObj

             if(this@taylor.order == 0){
               message("Cannot execute test with no alternate hypothesis. Please set a valid taylor.order")
               return(NaN)
             }

             # Test Method: Regress psi2_1 on 1/gt*(dgdt and dgdt2)
             # 1. Calc derivatives of params dgdt = Tx1 or Tx4 or Tx7 or...
             #    NCOL(dgdt) increases with the order of TV function.
             dgdt <- .dg_dt(this)

             # 2. Calc derivatives of taylor pars (linearised component) under the null
             dgdt2 <- .dg_dt2(this@st)
             dgdt2 <- dgdt2[,(1:this@taylor.order),drop=FALSE]

             g <- .calculate_g(this)
             X <- cbind(dgdt,dgdt2)/g

             # 3. Invert crossprod(X) to calculate SSR1
             Xinv <- NULL
             try(Xinv <- qr.solve(crossprod(X)))
             if (is.null(Xinv)){
               rm(g,dgdt,dgdt2)
               return(NaN)
             }

             # 4. Calculate psi2_1 to calculate SSR0
             psi2_1 <- matrix(data=(e^2/g-1),nrow = this@Tobs,ncol = 1)

             # 5. Calc the TestStat:
             SSR0 <- sum(psi2_1*psi2_1)    # Scalar
             SSR1 <- sum((psi2_1-X%*%Xinv%*%t(X)%*%psi2_1)^2)

             Result <- this@Tobs*(SSR0-SSR1)/SSR0

             # Tidy up & release memory before returning:
             rm(this,psi2_1,g,X,Xinv,dgdt,dgdt2)

             # Return:
             Result

           }
)

## -- test.LM.Robust(e,tv) ####
setGeneric(name="test.LM.Robust",
           valueClass = "numeric",
           signature = c("e","tvObj"),
           def = function(e,tvObj){
             this <- tvObj

             if(this@taylor.order == 0){
               message("Cannot execute test with no alternate hypothesis. Please set a valid taylor.order")
               return(NaN)
             }
             # 1. Calc derivatives of params dgdt = Tx1 or Tx4 or Tx7 or...
             #    NCOL(dgdt) increases with the order of TV function.
             dgdt <- .dg_dt(this)

             # 2. Calc derivatives of taylor pars (linearised component) under the null
             dgdt2 <- .dg_dt2(this@st)
             dgdt2 <- dgdt2[,(1:this@taylor.order),drop=FALSE]

             g <- .calculate_g(this)
             X <- dgdt/g

             # 3. Invert crossprod(X) to calculate SSR1
             Xinv <- NULL
             try(Xinv <- qr.solve(crossprod(X)))
             if (is.null(Xinv)){
               message("error")
               rm(g,X,dgdt,dgdt2)
               return(NaN)
             }

             XXXX <- X%*%Xinv%*%t(X)
             Y <- as.matrix(dgdt2/g)
             W <- as.matrix(Y-XXXX%*%Y)

             #4. Regress 1 on (psi2-1)*w, and compute SSR
             psi2_1 <- as.vector(e^2/g - 1)
             X <- psi2_1*W  #psi2_1 must be a vector for this!!

             #5. Compute test statistic:
             Xinv <- NULL
             try(Xinv <- qr.solve(crossprod(X)))
             if(is.null(Xinv)) {
               message("error")
               rm(psi2_1,g,W,Y,X,XXXXdgdt,dgdt2)
               return(NaN)
             }

             Result <- this@Tobs-sum(diag(this@Tobs)-(X%*%Xinv%*%t(X)))

             # Tidy up & release memory before returning:
             rm(this,psi2_1,g,W,Y,X,XXXX,Xinv,dgdt,dgdt2)

             # Return:
             Result

           }
)

## -- SetTaylorOrder(tv) ####
setGeneric(name="setTaylorOrder",
           valueClass = "tv_class",
           signature = c("taylor.order","tvObj"),
           def = function(taylor.order,tvObj){
             this <- tvObj

             if(taylor.order > 0 && taylor.order < 5){
               this@taylor.order <- as.integer(taylor.order)
             } else{
               message("Invalid Taylor Order: Values 1 to 4 are supported")
             }
             return(this)
           }
)

## -- getTestStats(tv) ####
setGeneric(name="getTestStats",
           valueClass = "list",
           signature = c("e","tvObj"),
           def = function(e,tvObj){
             this <- list()

             this$TR2 <- test.LM.TR2(e,tvObj)
             this$Robust <- test.LM.Robust(e,tvObj)

             return(this)
           }
)





## --- PRIVATE TV METHODS --- ####

#### ==================  Simulate Test Stat Distribution  ================== ###

## -- testStatDist ####
setGeneric(name="testStatDist",
           valueClass = "list",
           signature = c("refdata","tvObj","reftests","simcontrol"),
           def = function(refdata,tvObj,reftests,simcontrol){
             this <- tvObj

             # 1. Setup the default params
             library(doParallel)
             if(!is.null(simcontrol$saveAs)) {
               saveAs <- simcontrol$saveAs
             } else {
               saveAs <- paste("TestStatDist-",strftime(Sys.time(),format="%Y%m%d-%H%M%S",usetz = FALSE),sep = "")
             }
             if(!is.null(simcontrol$numLoops)) numLoops <- simcontrol$numLoops else numLoops <- 1100
             if(!is.null(simcontrol$numCores)) numCores <- simcontrol$numCores else numCores <- detectCores() - 1

             # 2. Create Sim_Dist folder (if not there) & set Save filename
             if (!dir.exists(file.path(getwd(),"Sim_Dist"))) dir.create(file.path(getwd(),"Sim_Dist"))
             saveAs <- paste0(file.path("Sim_Dist",saveAs),".RDS")

             # 3. Load the generated data with Garch and add the 'g' from our TV object
             refdata <- refdata*sqrt(this@g)

             # 4. Setup the matrix to store the simulation results
             testStats <- matrix(NA,nrow=numLoops,ncol=8)

             # 5. Setup the parallel backend
             Sys.setenv("MC_CORES" = numCores)
             cl <- makeCluster(numCores)
             registerDoParallel(cl, cores = numCores)
             #

             # 6. Perform the simulation - in parallel
             estCtrl <- list(calcSE = FALSE, verbose = FALSE)
             if(is.null(reftests$TR2)) reftests$TR2 <- NaN
             if(is.null(reftests$Robust)) reftests$Robust <- NaN

             tmr <- proc.time()
             timestamp(prefix = "Starting to build Test Stat Distribution - ",suffix = "\nPlease be patient as this may take a while...\n")

             testStats <- foreach(b = 1:numLoops, .inorder=FALSE, .combine=rbind, .verbose = FALSE) %dopar% {

               sim_e <- as.vector(refdata[,b])
               TV <- estimateTV(sim_e,this,estCtrl)    # Note: The tv params don't change, only the sim_e changes
               if (!TV$Estimated$error) {
                 if(is.nan(reftests$TR2)) simTEST1 <- NaN else simTEST1 <- test.LM.TR2(sim_e,TV)
                 if(is.nan(reftests$Robust)) simTEST2 <- NaN else simTEST2 <- test.LM.Robust(sim_e,TV)
                 runSimrow <- c(b,reftests$TR2,simTEST1,as.integer(simTEST1 > reftests$TR2),reftests$Robust,simTEST2,as.integer(simTEST2 > reftests$Robust),TV$Estimated$value)
               }
               # Progress indicator:
               #if(b/100==round(b/100)) cat(".")

               #Result:
               runSimrow

             } # End: foreach(b = 1:numloops,...

             # 7. Save the distribution & stop the parallel cluster
             if(!is.na(saveAs)) try(saveRDS(testStats,saveAs))
             stopCluster(cl)

             # 8. Extract Test P_Values from Results & express as %
             colnames(testStats) <- c("b","Ref$LMTR2","Stat_TR2","Pval_TR2","Ref$LMRobust","Stat_Robust","Pval_Robust","Estimated_LL")
             Test <- list()
             Test$p_TR2 <- round(100*mean(testStats[,"Pval_TR2"],na.rm = TRUE),3)
             Test$p_ROB <- round(100*mean(testStats[,"Pval_Robust"],na.rm = TRUE),3)
             Test$TestStatDist <- testStats

             # 9. Print the time taken to the console:
             cat("\nTest Stat Distribution Completed \nRuntime:",(proc.time()-tmr)[3],"seconds\n")

             # 10. Attempt to release memory:
             rm(refdata,testStats)

             # Return:
             return(Test)

           }
)

setMethod("testStatDist",signature = c("matrix","tv_class","list","missing"),
          function(refdata,tvObj,reftests){
            simControl <- list()
            simControl$saveAs <- paste("TestStatDist-",strftime(Sys.time(),format="%Y%m%d-%H%M%S",usetz = FALSE))
            simControl$numLoops <- 1100
            simControl$numCores <- parallel::detectCores() - 1
            testStatDist(refdata,tvObj,reftests,simControl)
          })


## Set the initial parameters ####
setGeneric(name=".setInitialPars",
           valueClass = "tv_class",
           signature = c("tvObj"),
           def = function(tvObj){
             this <- tvObj

             nrLoc <- this@nr.transitions + length(this$shape[this$shape==tvshape$double])
             locNum <- 1
             locDen <- nrLoc + 1
             pars <- NULL
             parNames <- NULL
             for(n in 1:this@nr.transitions){
               loc1 <- round(locNum/locDen,4)
               if(this$shape[n] == tvshape$double) {
                 loc2 <- round((locNum+1)/locDen,4)
                 locNum <- locNum + 2
               } else {
                 loc2 <- NA
                 locNum <- locNum + 2
               }
               pars <- c(pars,1,3,loc1,loc2)
             }
             this$pars <- matrix(pars,nrow=4)
             return(this)
           }
)

## Estimated Pars to Matrix ####
setGeneric(name=".estimatedParsToMatrix",
           valueClass = "tv_class",
           signature = c("tvObj","optimpars"),
           def = function(tvObj,optimpars){
             this <- tvObj

             if(this@nr.transitions == 0) stop("There are no parameters on this tv object")

             # Add NA's for all missing locn.2 pars:
             naPars <- NULL
             for (i in seq_along(this$shape)) {
               if (this$shape[i] == tvshape$double) {
                 naPars <- c(naPars,optimpars[1:4])
                 optimpars <- optimpars[-(1:4)]
               } else {
                 naPars <- c(naPars,optimpars[1:3],NA)
                 optimpars <- optimpars[-(1:3)]
               }
             }
             this$Estimated$pars <- matrix(naPars,nrow=4,ncol=NROW(this$shape),dimnames=list(c("deltaN","speedN","locN1","locN2"),NULL))

             # Return
             this
           }
)

## -- .dg_dt(tv) ####
setGeneric(name=".dg_dt",
           valueClass = "matrix",
           signature = c("tvObj"),
           def =  function(tvObj){

             this <- tvObj

             rtn <- matrix(nrow=this@Tobs,ncol=this@nr.pars)
             col_idx <- 0

             if(this@delta0free){
               col_idx <- col_idx + 1
               rtn[,col_idx] <- 1  # derivative of delta0
             }

             if (this@nr.transitions > 0) {
               # initialise some variables
               stdev_st <- sd(this@st)
               st_c <- speed_transf <- Gi <- 0

               for (i in 1:this@nr.transitions) {

                 if(this$shape[i] == tvshape$single) st_c <- this@st - this$Estimated$pars["locN1",i]
                 if(this$shape[i] == tvshape$double) st_c <- (this@st - this$Estimated$pars["locN1",i]) * (this@st - this$Estimated$pars["locN2",i])
                 if(this$shape[i] == tvshape$double1loc) st_c <- (this@st - this$Estimated$pars["locN1",i])^2

                 if(this$speedopt == speedopt$gamma) {
                   speed_transf <- this$Estimated$pars["speedN",i]
                   Gi <- 1/(1+exp(-this$Estimated$pars["speedN",i] * st_c))
                 }
                 if(this$speedopt == speedopt$gamma_std) {
                   speed_transf <- this$Estimated$pars["speedN",i]/stdev_st
                   Gi <- 1/(1+exp(-this$Estimated$pars["speedN",i] * st_c/stdev_st))
                 }
                 if(this$speedopt == speedopt$eta) {
                   speed_transf <- exp(this$Estimated$pars["speedN",i])
                   Gi <- 1/(1+exp(-exp(this$Estimated$pars["speedN",i]) * st_c))
                 }

                 deriv_const <- this$Estimated$pars["deltaN",i]*speed_transf*Gi*(1-Gi)

                 col_idx <- col_idx + 1
                 rtn[,col_idx] <- Gi    # derivative of delta1..n
                 col_idx <- col_idx + 1
                 rtn[,col_idx] <- deriv_const*st_c    # derivative of speed1..n

                 if(this$shape[i] == tvshape$single){
                   col_idx <- col_idx + 1
                   rtn[,col_idx] <- -deriv_const    # derivative of loc1..n (shape=TVshape$single)
                 }
                 if(this$shape[i] == tvshape$double){
                   col_idx <- col_idx + 1
                   rtn[,col_idx] <- -deriv_const*(this@st-this$Estimated$pars["locN1",i])  # derivative of loc1..n (shape=TVshape$double)
                   col_idx <- col_idx + 1
                   rtn[,col_idx] <- -deriv_const*(this@st-this$Estimated$pars["locN2",i])  # derivative of loc2..n (shape=TVshape$double)
                 }
                 if(this$shape[i] == tvshape$double1loc){
                   col_idx <- col_idx + 1
                   rtn[,col_idx] <- -deriv_const*2*(this@st-this$Estimated$pars["locN1",i])    # derivative of loc1..n (shape=TVshape$double1loc)
                 }

               } # End: for loop

             } # End: if (this@nr.transitions > 0)

             return(rtn)

           }
)


## -- .dg_dt2(tv@st) ####
setGeneric(name=".dg_dt2",
           valueClass = "matrix",
           signature = c("st"),
           def =  function(st){

             rtn <- matrix(1,NROW(st),4)
             rtn[,1] <- st
             rtn[,2] <- st^2
             rtn[,3] <- st^3
             rtn[,4] <- st^4
             # Return:
             rtn

           }
)



## -- .calculate_g(tv) ####
setGeneric(name=".calculate_g",
           valueClass = "numeric",
           signature = c("tvObj"),
           def = function(tvObj){

             this <- tvObj
             # 1. Initialise g to a constant variance = delta0
             if(is.null(this$Estimated$delta0)){
               # Set defaults if the TV object has not been estimated yet
               g <- rep(this$delta0,this@Tobs)
               this$Estimated$pars <- this$pars
             }else {
               g <- rep(this$Estimated$delta0,this@Tobs)
             }

             # 2. Update based on any transition parameters in the model
             if (this@nr.transitions > 0){
               st_c <- 0
               Gi <- 0
               # calulate 'g'
               for (i in 1:this@nr.transitions) {
                 if(this$shape[i] == tvshape$single) st_c <- this@st - this$Estimated$pars["locN1",i]
                 if(this$shape[i] == tvshape$double) st_c <- (this@st - this$Estimated$pars["locN1",i]) * (this@st - this$Estimated$pars["locN2",i])
                 if(this$shape[i] == tvshape$double1loc) st_c <- (this@st - this$Estimated$pars["locN1",i])^2

                 if(this$speedopt == speedopt$gamma) Gi <- 1/(1+exp(-this$Estimated$pars["speedN",i] * st_c))
                 if(this$speedopt == speedopt$gamma_std) Gi <- 1/(1+exp(-this$Estimated$pars["speedN",i] * st_c/sd(this@st)))
                 if(this$speedopt == speedopt$eta) Gi <- 1/(1+exp(-exp(this$Estimated$pars["speedN",i]) * st_c))

                 g <- g + this$Estimated$pars["deltaN",i]*Gi
               }
             }

             #Return:
             g
           }
)

setGeneric(name="get_g",
           valueClass = "numeric",
           signature = c("tvObj"),
           def = function(tvObj){
            .calculate_g(tvObj)
          }
)


## -- loglik.tv.univar() ####
setGeneric(name="loglik.tv.univar",
           valueClass = "numeric",
           signature = c("optimpars","e","tvObj"),
           def = function(optimpars,e,tvObj){

             this <- tvObj
             error <- -1e10

             # Copy the optimpars into a local tv_object
             if (this@delta0free) {
               this$Estimated$delta0 <- optimpars[1]
               this <- .estimatedParsToMatrix(this,tail(optimpars,-1))
             } else{
               if(is.null(this$Estimated$delta0)) this$Estimated$delta0 <- this$delta0
               this <- .estimatedParsToMatrix(this,optimpars)
             }

             # Do paramater boundary checks:
             # Check 1: Check that delta0 is positive
             if (this$Estimated$delta0 < 0) return(error)

             if (this@nr.transitions > 0){
               # We have some Tv$pars
               vecSpeed <- this$Estimated$pars["speedN",(1:this@nr.transitions)]
               vecLoc1 <- this$Estimated$pars["locN1",(1:this@nr.transitions)]
               vecLoc2 <- this$Estimated$pars["locN2",(1:this@nr.transitions)]

               # Check 2: Check the boundary values for speed params:
               #speedoptions: 1=gamma, 2=gamma/std(st), 3=exp(eta), 4=1/lambda^2
               maxSpeed <- switch(this$speedopt,1000,(1000/sd(this@st)),7.0,0.30)
               if (max(vecSpeed) > maxSpeed) return(error)
               if (min(vecSpeed) < 0) return(error)

               # Check 3: Check the loc1 locations fall within min-max values of st
               # We must have at least 1 loc1 to be inside this shape..loop, so no need to check if loc1 contains a valid value:
               if (min(vecLoc1) < min(this@st)) return(error)
               if (max(vecLoc1) > max(this@st)) return(error)

               # Check 4: Check that loc1.1 < loc1.2 .. locN.1 < locN.2 for all G(i)
               # Method: Subtract loc1_pos vector from loc2_pos vector and ensure it is positive:
               tmp <- vecLoc2 - vecLoc1
               # Note: tmp will contain NA wherever a loc2 element was NA - we can strip these out:
               if (sum(tmp < 0,na.rm = TRUE) > 0) return(error)

               # Check 5: Check the loc2 locations fall within min-max values of st
               # Confirm we have at least one valid numeric loc 2, before checking min & max:
               if (any(!is.na(vecLoc2))) {
                 if (min(vecLoc2,na.rm = TRUE) < min(this@st)) return(error)
                 if (max(vecLoc2,na.rm = TRUE) > max(this@st)) return(error)
               }

               # Check 6: Check that loc1.1 < loc2.1 where 2 locations exist... for all G(i)
               # We do need to have at least 2 locations for this error check
               if (NROW(vecLoc1) > 1) {
                 v1 <- head(vecLoc1,-1)
                 v2 <- tail(vecLoc1,-1)
                 if (sum(v2-v1 < 0) > 0) return(error)
               }

             }# End: paramater boundary checks:

             g <- .calculate_g(this)
             if (min(g,na.rm = TRUE) <= 0) return(error)

             #Return the LogLiklihood value:
             sum( -0.5*log(2*pi) - 0.5*log(g) - 0.5*(e^2)/g )

           }
)

## --- Override Methods --- ####

## -- plot() ####
setMethod("plot",signature = c(x="tv_class",y="missing"),
          function(x, y,...){
            this <- x
            plot.default(x=this@g, type='l', ylab = "Cond.Variance", ...)
          })


## -- summary() ####
setMethod("summary",signature="tv_class",
          function(object,...){
            this <- object
            results <- NULL

            if(is.null(this$Estimated)){
              #
            } else{

              # Calculate significance indicator for delta0
              if(is.null(this$Estimated$delta0_se)) this$Estimated$delta0_se <- NaN
              se <- this$Estimated$delta0_se
              d0 <- this$Estimated$delta0
              d0Sig <- ""
              if(!is.nan(se)){
                if(se*2.576 < abs(d0)) { d0Sig <- "***" }
                else if(se*1.96 < abs(d0)) { d0Sig <- "** " }
                else if(se*1.645 < abs(d0)) { d0Sig <- "*  " }
              }

              parsVec <-  round(as.vector(this$Estimated$pars),6)
              if(!is.null(this$Estimated$se) ){
                seVec <- round(as.vector(this$Estimated$se),6)
                seVecSig <- vector("character", length(seVec))

                for(n in seq_along(parsVec)){
                  if(is.nan(seVec[n])) {
                    seVecSig[n] <- "   "
                  } else {
                    # Calculate a significance indicator
                    if(seVec[n]*2.576 < abs(parsVec[n]) ) { (seVecSig[n] <- "***") }
                    else if(seVec[n]*1.96 < abs(parsVec[n]) ) { (seVecSig[n] <- "** ") }
                    else if(seVec[n]*1.645 < abs(parsVec[n]) ) { (seVecSig[n] <- "*  ") }
                  }
                }
              } else {
                seVec <- rep(NaN,length(this$pars))
                seVecSig <- rep("   ", length(seVec))
              }

              seMat <- matrix(seVec,nrow=4)
              colnames(seMat) <- paste("se" ,1:this@nr.transitions,sep = "")
              # Build Results table and insert the significance indicators
              results <- data.frame(NA,stringsAsFactors = FALSE)
              for (n in 1:NCOL(this$Estimated$pars)){
                sig <- matrix(seVecSig[1:4],nrow=4)
                results <- cbind(results,round(this$Estimated$pars[,n,drop=F],6),seMat[,n,drop=F],sig)
                seVecSig <- tail(seVecSig,-4)
              }
            }

            cat("\n\nTV OBJECT\n")
            if(this@taylor.order > 0) cat("\nTaylor Expansion Order: ",this@taylor.order)
            cat("\nTransition Shapes:", this$shape ,"\n")
            cat("\nEstimation Results:\n")
            cat("\nDelta0 =",round(this$Estimated$delta0,6),"se0 = ",round(this$Estimated$delta0_se,6),d0Sig,"\n\n")
            print(results[,-1])
            cat("\nLog-likelihood value(TV): ",this$Estimated$value)

          })



## --- GARCH_CLASS Definition --- ####

garch <- setClass(Class = "garch_class",
                  slots = c(h="numeric",nr.pars="integer",order="numeric"),
                  contains = c("namedList")
)

setMethod("initialize","garch_class",
          function(.Object,...){
            .Object <- callNextMethod(.Object,...)
            .Object@nr.pars <- as.integer(0)
            .Object@order <- as.integer(0)
            # Return:
            .Object
          })

setGeneric(name="garch",
           valueClass = "garch_class",
           signature = c("type","order"),
           def = function(type,order){

             garchtype <- list(noGarch=0,general=1,gjr=2)

             this <- new("garch_class")
             this$type <- type
             if(type == garchtype$noGarch) return(this)

             this@order <- order
             this <- .setInitPars(this)
             this$optimcontrol <- list(fnscale = -1, maxit = 1000, reltol = 1e-7)

             return(this)
           }
)

## Constructor with 1 param - creates a Garch(1,1)
setMethod("garch",signature = c("numeric","missing"),
          function(type){
            # Create a GARCH(1,1) model
            garch(type,c(1,1))
          })


## --- Public GARCH Methods --- ####

## -- estimateGARCH() ####
setGeneric(name="estimateGARCH",
           valueClass = "garch_class",
           signature = c("e","garchObj","estimationControl"),
           def = function(e,garchObj,estimationControl){
             this <- garchObj

             if(this$type == garchtype$noGarch) {
               message("Cannot estimateGARCH for type: NoGarch")
               return(this)
             }

             # Attach results of estimation to the object
             this$Estimated <- list()
             this$Estimated$method <- "MLE"

             #
             if(!is.list(estimationControl)) estimationControl <- list()
             if(!is.null(estimationControl$calcSE)) calcSE <- estimationControl$calcSE else calcSE <- FALSE
             if(!is.null(estimationControl$verbose)) verbose <- estimationControl$verbose else verbose <- FALSE
             if (verbose) {
               this$optimcontrol$trace <- 10
               cat("\nEstimating GARCH object...\n")
             } else this$optimcontrol$trace <- 0

             # Get Optimpars from garch$pars
             optimpars <- as.vector(this$pars)
             names(optimpars) <- rownames(this$pars)

             # Now call optim:
             tmp <- NULL
             try(tmp <- optim(optimpars,loglik.garch.univar,gr=NULL,e,this, method="BFGS",control=this$optimcontrol,hessian=calcSE))

             # An unhandled error could result in a NULL being returned by optim()
             if (is.null(tmp)) {
               this$Estimated$value <- -Inf
               this$Estimated$error <- TRUE
               warning("estimateGARCH() - optim failed unexpectedly and returned NULL. Check the optim controls & starting params")
               return(this)
             }
             if (tmp$convergence!=0) {
               this$Estimated$value <- -Inf
               this$Estimated$error <- TRUE
               this$Estimated$optimoutput <- tmp
               warning("estimateGARCH() - failed to converge. Check the optim controls & starting params")
               return(this)
             }

             this$Estimated$value <- tmp$value
             this$Estimated$error <- FALSE

             this$Estimated$pars <- .parsVecToMatrix(this,tmp$par)
             # Get conditional variance
             this@h <- .calculate_h(this,e)

             # Calc Std Errors
             if (calcSE) {
               this$Estimated$hessian <- round(tmp$hessian,5)
               StdErrors <- NULL
               try(StdErrors <- sqrt(-diag(qr.solve(tmp$hessian))))
               if(is.null(StdErrors)) {
                 this$Estimated$se <- matrix(NA,nrow=this@nr.pars)
               }else {
                 this$Estimated$se <- matrix(StdErrors,nrow=this@nr.pars)
               }
               rownames(this$Estimated$se) <- rownames(this$pars)
               colnames(this$Estimated$se) <- "se"
             }
             if (verbose) this$Estimated$optimoutput <- tmp

             return(this)
           }
)

setMethod("estimateGARCH",signature = c("numeric","garch_class","missing"),
          function(e,garchObj){
            estimationControl <- list()
            estimationControl$calcSE <- FALSE
            estimationControl$verbose <- FALSE
            estimationControl$vartargetWindow <- 0
            estimateGARCH(e,garchObj,estimationControl)
          }
)


## == estimateGARCH_RollingWindow == ####
setGeneric(name="estimateGARCH_RollingWindow",
           valueClass = "garch_class",
           signature = c("e","garchObj","estimationControl"),
           def =  function(e,garchObj,estimationControl){
             this <- garchObj

             # == Validations == #
             if(this$type == garchtype$noGarch) {
               message("Cannot estimateGARCH for type: NoGarch")
               return(this)
             }

             if(!is.list(estimationControl)){
               message("A valid estimationControl list is required - see Help")
               return(this)
             } else {
               if(is.null(estimationControl$vartargetWindow)) {
                 message("A valid estimationControl$vartargetWindow length is required - see Help")
                 return(this)
               }else {
                 if(estimationControl$vartargetWindow <= 0) {
                   message("estimationControl$vartargetWindow length must be a positive value - see Help")
                   return(this)
                 }
               }
             }
             vartargetWindow <- estimationControl$vartargetWindow
             # == End: Validations == #

             # Attach results of estimation to the object
             this$Estimated <- list()

             #
             if(!is.null(estimationControl$calcSE)) calcSE <- estimationControl$calcSE else calcSE <- FALSE
             if(!is.null(estimationControl$verbose)) verbose <- estimationControl$verbose else verbose <- FALSE

             if (verbose) {
               this$optimcontrol$trace <- 10
               cat("\nEstimating GARCH object...\n")
             } else this$optimcontrol$trace <- 0

             # vartargetWindow is only used for initial estimation of the Garch
             this$Estimated$method <- paste0("MLE, variance-targetting a rolling Window of ",vartargetWindow, " observations")

             # Get Optimpars from garch$pars & remove omega
             optimpars <- as.vector(this$pars)
             names(optimpars) <- rownames(this$pars)
             # When var-targetting, omega is calculated, so...
             optimpars <- tail(optimpars,-1)

             # Now call optim:
             tmp <- NULL
             try(tmp <- optim(optimpars,.loglik.garch.rollingWin,gr=NULL,e,this,vartargetWindow, method="BFGS",control=this$optimcontrol,hessian=calcSE))

             # An unhandled error could result in a NULL being returned by optim()
             if (is.null(tmp)) {
               this$Estimated$value <- -Inf
               this$Estimated$error <- TRUE
               warning("estimateGARCH() - optim failed and returned NULL. Check the optim controls & starting params")
               return(this)
             }
             if (tmp$convergence!=0) {
               this$Estimated$value <- -Inf
               this$Estimated$error <- TRUE
               this$Estimated$optimoutput <- tmp
               warning("estimateGARCH() - failed to converge. Check the optim controls & starting params")
               return(this)
             }

             this$Estimated$value <- tmp$value
             this$Estimated$error <- FALSE

             #Update the GARCH object paramters using optimised pars:
             omega <- 1 - tmp$par[1] - tmp$par[2]
             tmp$par <- c(omega,tmp$par)
             this$Estimated$pars <- .parsVecToMatrix(this,tmp$par)

             # Get conditional variance - 'h'
             Tobs <- NROW(e)
             h <- rep(0,Tobs)
             h[1] <- sum(e*e)/Tobs
             halfWindow <- round(vartargetWindow/2)

             for(t in 2:Tobs){

               if( t <= halfWindow || t > (Tobs-halfWindow) ) {
                 h[t] <- var(e)
               } else {
                 start <- t - halfWindow
                 end <- min(t + halfWindow,Tobs)
                 localVar <- var(e[start:end])
                 this$Estimated$pars["omega",1] <- (1 - this$Estimated$pars["alpha",1] - this$Estimated$pars["beta",1]) * localVar
                 h[t] <- this$Estimated$pars["omega",1] + this$Estimated$pars["alpha",1]*(e[t-1])^2 + this$Estimated$pars["beta",1]*h[t-1]
                 if(this$type == garchtype$gjr) h[t] <- h[t] + this$Estimated$pars["gamma",1]*(min(e[t-1],0))^2
               }
             }
             # End: Get conditional variance - 'h'


             # Calc Std Errors
             if (calcSE) {
               this$Estimated$hessian <- round(tmp$hessian,5)
               StdErrors <- NULL
               try(StdErrors <- sqrt(-diag(qr.solve(tmp$hessian))))
               if(is.null(StdErrors)) {
                 this$Estimated$se <- matrix(NA,nrow=(this@nr.pars))
               }else {
                 StdErrors <- c(NA,StdErrors)
                 this$Estimated$se <- matrix(StdErrors,nrow=(this@nr.pars))
               }
               rownames(this$Estimated$se) <- rownames(this$pars)
               colnames(this$Estimated$se) <- "se"
             }
             if (verbose) this$Estimated$optimoutput <- tmp

             return(this)
           }
)


## --- PRIVATE GARCH METHODS --- ####

## -- .setInitPars() -- ####

setGeneric(name=".setInitPars",
           valueClass = "garch_class",
           signature = c("garchObj"),
           def = function(garchObj){
             this <- garchObj

             if(this$type == garchtype$noGarch) {
               message("Cannot create Garch$pars for type: NoGarch")
               return(this)
             }

             maxLag <- max(this@order)

             # Set the row names:
             GarchparsRownames <- c("omega","alpha","beta","gamma")

             if(this$type == garchtype$general) {
               this@nr.pars <- as.integer(3)
               pars <- matrix(nrow = this@nr.pars,ncol = maxLag)
               rownames(pars) <- GarchparsRownames[1:this@nr.pars]
               for(n in 1:maxLag){
                 pars["omega",n] <- 0.05
                 pars["alpha",n] <- 0.05
                 pars["beta",n] <- 0.85
               }
               this$pars <- pars
             }
             if(this$type == garchtype$gjr) {
               this@nr.pars <- as.integer(4)
               pars <- matrix(nrow = this@nr.pars,ncol = maxLag)
               rownames(pars) <- GarchparsRownames[1:this@nr.pars]
               for(n in 1:maxLag){
                 pars["omega",n] <- 0.05
                 pars["alpha",n] <- 0.05
                 pars["beta",n] <- 0.85
                 pars["gamma",n] <- 0.05
               }
               this$pars <- pars
             }
             ## TODO: Implement in future release
             # if(this$type == garchtype$gjr_alpha0) {
             #   this@nr.pars <- as.integer(3)
             #   pars <- matrix(nrow = this@nr.pars,ncol = maxLag)
             #   rownames(pars) <- GarchparsRownames[1:(this@nr.pars + 1)]
             #   for(n in 1:maxLag){
             #     pars["omega",n] <- 0.05
             #     pars["alpha",n] <- 0.0
             #     pars["beta",n] <- 0.85
             #     pars["gamma",n] <- 0.05
             #   }
             #   this$pars <- pars
             # }

             return(this)
           }
)

## -- .parsVecToMatrix() ####
setGeneric(name=".parsVecToMatrix",
           valueClass = "matrix",
           signature = c("garchObj","pars"),
           function(garchObj,pars){
             this <- garchObj

             if(this$type == garchtype$noGarch) {
               message("Cannot create Garch Params for type: NoGarch")
               return(this)
             }

             maxLag <- max(this@order)

             # Set the row names:
             garchparsRownames <- c("omega","alpha","beta","gamma")
             # Return the formatted matrix
             matrix(pars,nrow = this@nr.pars ,ncol = maxLag,dimnames = list(garchparsRownames[1:this@nr.pars],"Est"))

           }
)

## -- .calculate_h() ####
setGeneric(name=".calculate_h",
           valueClass = "numeric",
           signature = c("garchObj","e"),
           def = function(garchObj,e){

             this <- garchObj

             if(this$type == garchtype$noGarch) {
               message("Cannot calculate h(t) for type: NoGarch")
               return(h)
             }

             Tobs <- NROW(e)
             h <- rep(0,Tobs)
             h[1] <- sum(e*e)/Tobs

             # TODO: Extend the below to handle more lags (higher order Garch)
             for(t in 2:Tobs) {
               h[t] <- this$Estimated$pars["omega",1] + this$Estimated$pars["alpha",1]*(e[t-1])^2 + this$Estimated$pars["beta",1]*h[t-1]
               if(this$type == garchtype$gjr) h[t] <- h[t] + this$Estimated$pars["gamma",1]*(min(e[t-1],0))^2
             }

             return(h)
           }

)

setGeneric(name="get_h",
           valueClass = "numeric",
           signature = c("garchObj","e"),
           def = function(garchObj,e){
             this <- garchObj

             if(this$type == garchtype$noGarch) {
               message("Cannot get h(t) for type: NoGarch")
               return(h)
             }

             Tobs <- NROW(e)
             h <- rep(0,Tobs)
             h[1] <- sum(e*e)/Tobs

             # TODO: Extend the below to handle more lags (higher order Garch)
             for(t in 2:Tobs) {
               h[t] <- this$pars["omega",1] + this$pars["alpha",1]*(e[t-1])^2 + this$pars["beta",1]*h[t-1]
               if(this$type == garchtype$gjr) h[t] <- h[t] + this$pars["gamma",1]*(min(e[t-1],0))^2
             }

             return(h)
           }

)

## -- loglik.garch.univar() ####
setGeneric(name="loglik.garch.univar",
           valueClass = "numeric",
           signature = c("optimpars","e","garchObj"),
           def =  function(optimpars,e,garchObj){

             error <- -1e10
             this <- garchObj

             ## ======== constraint checks ======== ##
             # Check if any parameter is negative:
             if(min(optimpars,na.rm = TRUE) <= 0) return(error)
             if (optimpars["alpha"] + optimpars["beta"] >= 1) return(error)

             ## ======== calculate loglikelihood ======== ##

             this$Estimated$pars <- .parsVecToMatrix(this,optimpars)
             h <- .calculate_h(this,e)

             #Return the LogLiklihood value:
             sum( -0.5*log(2*pi) - 0.5*log(h) - 0.5*(e*e)/h )

           }
)



## -- .loglik.garch.rollingWin() ####
setGeneric(name=".loglik.garch.rollingWin",
           valueClass = "numeric",
           signature = c("optimpars","e","garchObj","vartargetWindow"),
           def =  function(optimpars,e,garchObj,vartargetWindow){

             error <- -1e10
             this <- garchObj

             ## ======== constraint checks ======== ##
             # Check if any parameter is negative:
             if(min(optimpars,na.rm = TRUE) <= 0) return(error)
             if (optimpars["alpha"] + optimpars["beta"] >= 1) return(error)

             ## ======== calculate loglikelihood ======== ##

             estPars <- optimpars
             omega <- 1 - optimpars[1] - optimpars[2]
             estPars <- c(omega,optimpars)
             this$Estimated$pars <- .parsVecToMatrix(this,estPars)

             # Get conditional variance - 'h'
             Tobs <- NROW(e)
             h <- rep(0,Tobs)
             h[1] <- sum(e*e)/Tobs
             halfWindow <- round(vartargetWindow/2)

             for(t in 2:Tobs){

               if( t <= halfWindow || t > (Tobs-halfWindow) ) {
                 h[t] <- var(e)
               } else {
                 start <- t - halfWindow
                 end <- min(t + halfWindow,Tobs)
                 localVar <- var(e[start:end])
                 this$Estimated$pars["omega",1] <- (1 - this$Estimated$pars["alpha",1] - this$Estimated$pars["beta",1]) * localVar
                 h[t] <- this$Estimated$pars["omega",1] + this$Estimated$pars["alpha",1]*(e[t-1])^2 + this$Estimated$pars["beta",1]*h[t-1]
                 if(this$type == garchtype$gjr) h[t] <- h[t] + this$Estimated$pars["gamma",1]*(min(e[t-1],0))^2
               }
             }
             # End: Get conditional variance - 'h'

             #Return the LogLiklihood value:
             sum( -0.5*log(2*pi) - 0.5*log(h) - 0.5*(e*e)/h )

           }
)


## --- Override Methods --- ####

## -- plot() ####
setMethod("plot",signature = c(x="garch_class",y="missing"),
          function(x, y, ...){
            plot.default(x=x@h, type='l', ylab = "Cond.Variance", ...)
          }
)

## -- summary() ####
setMethod("summary",signature="garch_class",
          function(object,...){
            this <- object

            TypeNames <- c("No Garch","General","GJR Garch")

            if(this$type == garchtype$noGarch){
              cat("\nGARCH OBJECT\n")
              cat("\nType:",TypeNames[this$type+1])
              cat("\nCannot be estimated - this type only exists to support `mtvgarch` objects")
              return()
            }

            if(is.null(this$Estimated)){
              cat("\nGARCH OBJECT\n")
              cat("\nType:",TypeNames[this$type+1])
              cat("\nThis Garch object has not been estimated yet.")
              return()
            } else {

              parsVec <-  round(as.vector(this$Estimated$pars),6)
              parsRows <- NROW(this$Estimated$pars)

              if(!is.null(this$Estimated$se) ){
                seVec <- round(as.vector(this$Estimated$se),6)
                seVecSig <- vector("character", length(seVec))

                for(n in seq_along(parsVec)){
                  if(is.na(seVec[n])) {
                    seVecSig[n] <- "   "
                  } else {
                    # Calculate a significance indicator
                    if(seVec[n]*2.576 < abs(parsVec[n]) ) { (seVecSig[n] <- "***") }
                    else if(seVec[n]*1.96 < abs(parsVec[n]) ) { (seVecSig[n] <- "** ") }
                    else if(seVec[n]*1.645 < abs(parsVec[n]) ) { (seVecSig[n] <- "*  ") }
                  }
                }
              } else {
                seVec <- rep(NaN,length(this$pars))
                seVecSig <- rep("   ", length(seVec))
              }

              seMat <- matrix(seVec,nrow=parsRows)
              colnames(seMat) <- paste("se" ,1:max(this@order),sep = "")
              # Build Results table and insert the significance indicators
              results <- data.frame(NA,stringsAsFactors = FALSE)
              for (n in 1:NCOL(this$Estimated$pars)){
                sig <- matrix(seVecSig[1:parsRows],nrow=parsRows)
                results <- cbind(results,round(this$Estimated$pars[,n,drop=F],6),seMat[,n,drop=F],sig)
                seVecSig <- tail(seVecSig,-parsRows)
              }
            }

            cat("\nGARCH OBJECT\n")
            cat("\nType: ",TypeNames[this$type+1])
            cat("\nOrder: (",this@order[1],",",this@order[2],")")
            cat("\nMethod: ",this$Estimated$method,"\n")
            cat("\nEstimation Results:\n")
            print(results[,-1])
            cat("\nLog-likelihood value(GARCH): ",this$Estimated$value)

          }
)


## --- tvgarch_CLASS Definition --- ####
tvgarch <- setClass(Class = "tvgarch_class",
                    slots = c(IsEstimated="logical"),
                    contains = c("namedList")
)

## -- Initialise -- ####
setMethod("initialize","tvgarch_class",
          function(.Object){
            .Object$tvObj <- new("tv_class")
            .Object$garchObj <- new("garch_class")
            .Object@IsEstimated <- FALSE
            # Return:
            .Object
          })

## -- Constructor: tvgarch -- ####
setGeneric(name="tvgarch",
           valueClass = "tvgarch_class",
           signature = c("tvObj","garchObj"),
           def = function(tvObj,garchObj){

             this <- new("tvgarch_class")

             # Validate: Spit dummy if TV is not estimated
             if(is.null(tvObj$Estimated) ) {
               message("tvgarch-class objects require the tv component to be estimated before initialising.")
               return(this)
             }

             this$tvObj <- tvObj
             this$garchObj <- garchObj

             ## TODO:  Confirm & Fix if necessary!!!
             # Configure the tv object, based on Garch type
             if(isTRUE(this$tvObj@delta0free)){
               if(this$garchObj$type != garchtype$noGarch){
                 this$tvObj@delta0free <- FALSE
                 this$tvObj$optimcontrol$ndeps <- this$tvObj$optimcontrol$ndeps[2:this$tvObj@nr.pars]
                 this$tvObj$optimcontrol$parscale <- this$tvObj$optimcontrol$parscale[2:this$tvObj@nr.pars]
                 this$tvObj@nr.pars <- this$tvObj@nr.pars - as.integer(1)
               }
             }

             # Configure the optimcontrol list, based on tv & garch parameters
             this$optimcontrol <- list(fnscale = -1, maxit = 1000, reltol = 1e-7, trace = 10)
             if(!is.null(garchObj$optimcontrol$ndeps)){
               this$optimcontrol$ndeps <- garchObj$optimcontrol$ndeps
             }else this$optimcontrol$ndeps <- rep(1e-5,garchObj@nr.pars)
             #
             if(!is.null(garchObj$optimcontrol$parscale)){
               this$optimcontrol$parscale <- garchObj$optimcontrol$parscale
             }else this$optimcontrol$parscale <- this$optimcontrol$parscale <- rep(1,garchObj@nr.pars)
             #
             this$optimcontrol$ndeps <- c(this$optimcontrol$ndeps,this$tvObj$optimcontrol$ndeps)
             this$optimcontrol$parscale <- c(this$optimcontrol$parscale,this$tvObj$optimcontrol$parscale)

             cat("\ntvgarch object created successfully!\n")

             return(this)
           }
)

## -- loglik.tvgarch.univar() ####
setGeneric(name="loglik.tvgarch.univar",
           valueClass = "numeric",
           signature = c("e","g","h"),
           def = function(e,g,h){
             ll <- sum( -0.5*log(2*pi) - 0.5*log(g) - 0.5*log(h) - 0.5*(e^2/(g*h) ) )
             names(ll) <- "Loglik.Value"
             return(ll)
           }
)


## -- estimateTVGARCH -- ####
setGeneric(name="estimateTVGARCH",
           valueClass = "tvgarch_class",
           signature = c("e","tvgarchObj","estimationControl"),
           def = function(e,tvgarchObj,estimationControl){
             this <- tvgarchObj

             # Use the same starting params each time
             TV <- this$tvObj
             GARCH <- this$garchObj
             estCtrl <- estimationControl

             cat("\nStarting Estimation...")

             #==  First time being estimated ==#
             if(!isTRUE(this@IsEstimated)){
               this$Estimated <- list()
               GARCH <- estimateGARCH(e/sqrt(TV@g),GARCH,estCtrl)
               cat(".")

               # Put the initial best model into the Estimated list
               this$Estimated$tv <- TV
               this$Estimated$garch <- GARCH
               this$Estimated$startValue <- loglik.tvgarch.univar(e,TV@g,GARCH@h)
               this$Estimated$finalValue <- this$Estimated$startValue

               cat("\nTVGARCH Estimation Completed")
               cat("\n")

               this@IsEstimated <- TRUE

               return(this)

             } else {
               TV <- this$Estimated$tv
               GARCH <- this$Estimated$garch
               this$Estimated$startValue <- this$Estimated$finalValue
               this$Estimated$finalValue <- NA
             }

             #== Every other time being estimated ==#

             w <- e/sqrt(GARCH@h)
             #TV$pars <-  TV$Estimated$pars * 0.9
             TV$optimcontrol$reltol <- TV$optimcontrol$reltol / 10
             TV$optimcontrol$ndeps <- TV$optimcontrol$ndeps / 10
             TV <- estimateTV(w,TV,estCtrl)
             cat(".")

             if(!TV$Estimated$error){
               LL.tv <- max(loglik.tvgarch.univar(e,TV@g,GARCH@h),-1e100)
             } else LL.tv <- -1e100

             # If loglik value does not improve, override TV with old "best" pars
             if(LL.tv < this$Estimated$startValue) TV <- this$Estimated$tv else cat("\nTV Estimate Improved, now re-estimating Garch...\n")

             z <- e/sqrt(TV@g)
             #GARCH$pars <-  GARCH$Estimated$pars * 0.95
             GARCH$optimcontrol$reltol <- GARCH$optimcontrol$reltol / 10
             GARCH$optimcontrol$ndeps <- GARCH$optimcontrol$ndeps / 10
             GARCH <- estimateGARCH(z,GARCH,estCtrl)
             cat(".")

             LL.garch <- max(loglik.tvgarch.univar(e,TV@g,GARCH@h),-1e100)
             this$Estimated$finalValue <- LL.garch
             if(LL.garch - this$Estimated$startValue > 0.001) {
               this$Estimated$tv <- TV
               this$Estimated$garch <- GARCH
               cat("\nTVGARCH Estimation Completed - Improved",fill = TRUE)
             }else {
               cat("\nTVGARCH Estimation Completed - could not be improved",fill = TRUE)
             }

             return(this)
           }
)


## -- loglik.tvgarch.univar.1 ####
setGeneric(name="loglik.tvgarch.univar.1",
           valueClass = "numeric",
           signature = c("optimpars","e","tvgarchObj"),
           def =  function(optimpars,e,tvgarchObj){
             this <- tvgarchObj

             TV <- this$tvObj
             GARCH <- this$garchObj
             error <- -1e10

             # Calc g first:
             start <- GARCH@nr.pars + 1
             end <- length(optimpars)
             tvPars <- optimpars[start:end]

             ## ======== TV constraint checks ======== ##
             if(T){
               # Copy the optimpars into a local tv_object
               TV <- .estimatedParsToMatrix(TV,tvPars)

               # Do paramater boundary checks:

               if (TV@nr.transitions > 0){
                 # We have some Tv$pars
                 vecSpeed <- TV$Estimated$pars["speedN",(1:TV@nr.transitions)]
                 vecLoc1 <- TV$Estimated$pars["locN1",(1:TV@nr.transitions)]
                 vecLoc2 <- TV$Estimated$pars["locN2",(1:TV@nr.transitions)]

                 # Check 2: Check the boundary values for speed params:
                 #speedoptions: 1=gamma, 2=gamma/std(st), 3=exp(eta), 4=1/lambda^2
                 maxSpeed <- switch(TV$speedopt,1000,(1000/sd(TV@st)),7.0,0.30)
                 if (max(vecSpeed) > maxSpeed) return(error)
                 if (min(vecSpeed) < 0) return(error)

                 # Check 3: Check the loc1 locations fall within min-max values of st
                 # We must have at least 1 loc1 to be inside this shape..loop, so no need to check if loc1 contains a valid value:
                 if (min(vecLoc1) < min(TV@st)) return(error)
                 if (max(vecLoc1) > max(TV@st)) return(error)

                 # Check 4: Check that loc1.1 < loc1.2 .. locN.1 < locN.2 for all G(i)
                 # Method: Subtract loc1_pos vector from loc2_pos vector and ensure it is positive:
                 tmp <- vecLoc2 - vecLoc1
                 # Note: tmp will contain NA wherever a loc2 element was NA - we can strip these out:
                 if (sum(tmp < 0,na.rm = TRUE) > 0) return(error)

                 # Check 5: Check the loc2 locations fall within min-max values of st
                 # Confirm we have at least one valid numeric loc 2, before checking min & max:
                 if (any(!is.na(vecLoc2))) {
                   if (min(vecLoc2,na.rm = TRUE) < min(TV@st)) return(error)
                   if (max(vecLoc2,na.rm = TRUE) > max(TV@st)) return(error)
                 }

                 # Check 6: Check that loc1.1 < loc2.1 where 2 locations exist... for all G(i)
                 # We do need to have at least 2 locations for this error check
                 if (NROW(vecLoc1) > 1) {
                   v1 <- head(vecLoc1,-1)
                   v2 <- tail(vecLoc1,-1)
                   if (sum(v2-v1 < 0) > 0) return(error)
                 }

               }# End: paramater boundary checks:
             }

             g <- .calculate_g(TV)
             if (min(g,na.rm = TRUE) < 0) return(error)

             # Filter g out of the returns data & Calculate h
             w <- e/sqrt(g)
             garchPars <- optimpars[1:GARCH@nr.pars]
             names(garchPars) <- rownames(GARCH$pars)

             ## ======== GARCH constraint checks ======== ##
             if(T){
               # Check if any parameter is negative:
               if(min(garchPars,na.rm = TRUE) <= 0) return(error)
               if (garchPars["alpha"] + garchPars["beta"] >= 1) return(error)
             }

             GARCH$Estimated$pars <- .parsVecToMatrix(GARCH,garchPars)
             h <- .calculate_h(GARCH,w)
             if (min(h,na.rm = TRUE) < 0) return(error)

             ll <- sum( -0.5*log(2*pi) - 0.5*log(g) - 0.5*log(h) - 0.5*(e^2/(h*g) ) )
             names(ll) <- "Loglik.Value"
             return(ll)
           }
)

## -- .dh_dg(tvgarch) ####
setGeneric(name=".dh_dg",
           valueClass = "matrix",
           signature = c("e","tvgarchObj"),
           def =  function(e,tvgarchObj){

             this <- tvgarchObj
             Tobs <- this$tvObj@Tobs
             w <- e/sqrt(this$Estimated$tv@g)

             dhdg <- matrix(NA,0,0)  # Initialise return matrix

             if (this$garch$type == garchtype$noGarch){
               return(dhdg)
             } else if (this$garch$type == garchtype$general){
               v_garch <- cbind(c(0,rep(1,(Tobs-1))),c(0,w[1:(Tobs-1)]^2),c(0,this$Estimated$garch@h[1:(Tobs-1)])) # T x Num_garch_pars, each row = "1~w(i,t-1)^2~h(i,t-1)", i=1,...,N
             } else if (this$garch$type == garchtype$gjr){
               v_garch <- cbind(c(0,rep(1,(Tobs-1))),c(0,w[1:(Tobs-1)]^2),c(0,this$Estimated$garch@h[1:(Tobs-1)]),c(0,(min(w[1:(Tobs-1)],0))^2)) # T x Num_garch_pars, each row = "1~w(i,t-1)^2~h(i,t-1)", i=1,...,N
             }

             beta <- rep(this$Estimated$garch$Estimated$pars["beta",1],Tobs)
             dhdg <- .ar1.Filter(v_garch,beta) # T x Num_garch_pars, each row = dh(t).dgarchpars
             return(dhdg)

           }
)

## -- .dh_dt(tvgarch) ####
setGeneric(name=".dh_dt",
           valueClass = "matrix",
           signature = c("e","tvgarchObj"),
           def =  function(e,tvgarchObj){

             this <- tvgarchObj
             Tobs <- this$tvObj@Tobs
             w <- e/sqrt(this$Estimated$tv@g)

             dhdt <- matrix(NA,0,0)  # Initialise return matrix

             dgdt <- .dg_dt(this$Estimated$tv)  # T x TV@nr.pars (includes d0's derivative if it is a free param)
             g <- this$Estimated$tv@g # cbinds g(nt) as many times as g(n) has tv parameters

             if (this$garch$type != garchtype$noGarch){
               v_tv <- (-this$Estimated$garch$Estimated$pars["alpha",1] * c(0,1/g[1:(Tobs-1)])*c(0,w[1:(Tobs-1)]^2)) * c(0,dgdt[1:(Tobs-1)])
               beta <- rep(this$Estimated$garch$Estimated$pars["beta",1],Tobs)
               dhdt <- .ar1.Filter(v_tv,beta) # T x Num_tv_pars, each row = dh(t).dtvpar
             }

             return(dhdt)

           }
)

## -- test.misSpec1(tvgarch) ####
setGeneric(name="test.misSpec1",
           valueClass = "list",
           signature = c("e","tvgarchObj"),
           def =  function(e,tvgarchObj){
             this <- tvgarchObj
             rtn <- list()

             Tobs <- this$tvObj@Tobs
             g <- this$Estimated$tv@g
             h <- this$Estimated$garch@h

             # derivatives:
             dg_dtv <- .dg_dt(this$Estimated$tv)     # T x nr.tv.pars
             dh_dtv <- .dh_dt(e,this)                # T x nr.tv.pars
             dh_dga <- .dh_dg(e,this)                # T x nr.garch.pars
             df_dli <- .dg_dt2(this$tvObj@st)        # T x (testorder+1)

             # matrices
             u <- g^(-1) * dg_dtv     # (1/g)*(dg/dtvpars); T x nr.tv.pars
             x1 <- (h^(-1)) * dh_dtv  # (1/ht)*(dh/dtvpars); T x nr.tv.pars
             x2 <- (h^(-1)) * dh_dga  # (1/ht)*(dh/dgarchpars); T x nr.garch.pars
             #x3 <- (h^(-1)) * dh_dli # (1/ht)*(dh/dlinpars); T x nr.lin.pars  DON'T THINK WE NEED THIS AT ALL
             v3 <- (g^(-1)) * df_dli  # (1/gt)*(df/dlinpars); T x nr.lin.pars (=testorder+1)
             r1 <- cbind(u+x1,x2)     # T x (tot.tv+garch.pars)
             r2 <- v3                 # T x (testorder+1)

             # 1 estimate tvgjrgarch, get std.residuals z=e/sqrt(gh), get SSR0 = sum(z^2-1)
             z2_1 <- (e/sqrt(h*g))^2 - 1
             SSR0 <- t(z2_1) %*% z2_1
             # 2: regress z2_1 on r1~r2, get SSR
             X <- cbind(r1,r2) # T x ncol(r1)+ncol(r2)
             Y <- z2_1  # T x 1
             b <- solve(t(X) %*% X) %*% t(X) %*% Y  # vector len=ncol(X)
             resid <- Y-X %*% t(b)   # T x 1
             SSR1 <- t(resid) %*% resid # 1x1
             # LM stat
             rtn$LM <- Tobs * (SSR0-SSR1)/SSR0
             rtn$pVal <- pchisq(rtn$LM,df=NCOL(v3),lower.tail=FALSE)

             # ROBUST
             # 1 as above
             # 2 regress r2 on r1, get residual vectors
             resid <- matrix(0,Tobs,NCOL(r2))
             X <- r1
             for (i in 1:NCOL(r2)){
               Y <- r2[,i]
               b <- solve(t(X) %*% X) %*% t(X) %*% Y  # vector len=ncol(X)
               resid[,i] <- Y-X %*% t(b)   # T x 1
             }
             # regress 1 on (z2_1)resid, get SSR
             Y <- matrix(1,Tobs,1)
             X <- z2_1*resid
             b <- solve(t(X) %*% X) %*% t(X) %*% Y  # vector len=ncol(X)
             resid <- Y-X %*% t(b)   # T x 1
             SSR <- t(resid) %*% resid # 1x1
             # LM Robust
             rtn$LMrob <- Tobs-SSR
             rtn$pValrob <- pchisq(rtn$LMrob,df=NCOL(v3),lower.tail=FALSE)

             return(rtn)
           }

)

## -- test.misSpec2(tvgarch,type) ####
setGeneric(name="test.misSpec2",
           valueClass = "list",
           signature = c("e","tvgarchObj","type"),
           def =  function(e,tvgarchObj,type){
             # type 1: GARCH(1,1) vs GARCH(1,2)
             # type 2: GARCH(1,1) vs GARCH(2,1)
             # type 3: GARCH vs STGARCH

             this <- tvgarchObj
             rtn <- list()

             Tobs <- this$tvObj@Tobs
             g <- this$Estimated$tv@g
             h <- this$Estimated$garch@h
             w <- e/sqrt(g)
             z <- e/sqrt(g*h)
             z2 <- z^2
             z2_1 <- z^2 - 1

             # derivatives:
             dg_dtv <- .dg_dt(this$Estimated$tv)     # T x nr.tv.pars
             dh_dtv <- .dh_dt(e,this)                # T x nr.tv.pars
             dh_dga <- .dh_dg(e,this)                # T x nr.garch.pars

             # matrices
             u <- g^(-1) * dg_dtv     # (1/g)*(dg/dtvpars); T x nr.tv.pars
             x1 <- (h^(-1)) * dh_dtv  # (1/ht)*(dh/dtvpars); T x nr.tv.pars
             x2 <- (h^(-1)) * dh_dga  # (1/ht)*(dh/dgarchpars); T x nr.garch.pars
             r1 <- cbind(u+x1,x2)     # T x (tot.tv+garch.pars)
             if (type==1){
               r2 <- (h^(-1)) * lag0(w^2,2)  # T x 1
             }
             if (type==2){
               r2 <- (h^(-1)) * lag0(h,2)  # T x 1
             }
             if (type==3){
               r2 <- (h^(-1)) * cbind(lag0(w,1),lag0(w^3,1))  # T x 2
             }

             # 1 estimate tvgjrgarch, get std.residuals z=e/sqrt(gh), get SSR0 = sum(z^2-1)
             SSR0 <- t(z2_1) %*% z2_1
             # 2: regress z2_1 on r1~r2, get SSR
             X <- cbind(r1,r2) # T x ncol(r1)+ncol(r2)
             Y <- z2_1  # T x 1
             b <- solve(t(X) %*% X) %*% t(X) %*% Y  # vector len=ncol(X)
             resid <- Y-X %*% t(b)   # T x 1
             SSR1 <- t(resid) %*% resid # 1x1
             # LM stat
             rtn$LM <- Tobs * (SSR0-SSR1)/SSR0
             rtn$pVal <- pchisq(rtn$LM,df=NCOL(r2),lower.tail=FALSE)

             # ROBUST
             # 1 as above
             # 2 regress r2 on r1, get residual vectors
             resid <- matrix(0,Tobs,NCOL(r2))
             X <- r1
             for (i in 1:NCOL(r2)){
               Y <- r2[,i]
               b <- solve(t(X) %*% X) %*% t(X) %*% Y  # vector len=ncol(X)
               resid[,i] <- Y-X %*% t(b)   # T x 1
             }
             # regress 1 on (z2_1)resid, get SSR
             Y <- matrix(1,Tobs,1)
             X <- z2_1*resid
             b <- solve(t(X) %*% X) %*% t(X) %*% Y  # vector len=ncol(X)
             resid <- Y-X %*% t(b)   # T x 1
             SSR <- t(resid) %*% resid # 1x1
             # LM Robust
             rtn$LMrob <- Tobs-SSR
             rtn$pValrob <- pchisq(rtn$LMrob,df=NCOL(r2),lower.tail=FALSE)

             return(rtn)
           }

)



## -- test.misSpec3(tvgarch,maxLag) ####
setGeneric(name="test.misSpec3",
           valueClass = "list",
           signature = c("e","tvgarchObj","maxLag"),
           def =  function(e,tvgarchObj,maxLag){
             this <- tvgarchObj
             rtn <- list()

             Tobs <- this$tvObj@Tobs
             g <- this$Estimated$tv@g
             h <- this$Estimated$garch@h
             z <- e/sqrt(g*h)
             z2 <- z^2
             z2_1 <- z^2 - 1

             # derivatives:
             dg_dtv <- .dg_dt(this$Estimated$tv)     # T x nr.tv.pars
             dh_dtv <- .dh_dt(e,this)                # T x nr.tv.pars
             dh_dga <- .dh_dg(e,this)                # T x nr.garch.pars
             df_dli <- .dg_dt2(this$tvObj@st)        # T x (testorder+1)

             # matrices
             u <- g^(-1) * dg_dtv         # (1/g)*(dg/dtvpars); T x nr.tv.pars
             x1 <- (h^(-1)) * dh_dtv      # (1/ht)*(dh/dtvpars); T x nr.tv.pars
             x2 <- (h^(-1)) * dh_dga      # (1/ht)*(dh/dgarchpars); T x nr.garch.pars
             r1 <- cbind(u+x1,x2)         # T x (tot.tv+garch.pars)
             r2 <- lag0(z2,(1:maxLag))    # T x maxlag

             # 1 estimate tvgjrgarch, get std.residuals z=e/sqrt(gh), get SSR0 = sum(z^2-1)
             SSR0 <- t(z2_1) %*% z2_1
             # 2: regress z2_1 on r1~r2, get SSR
             X <- cbind(r1,r2) # T x ncol(r1)+ncol(r2)
             Y <- z2_1  # T x 1
             b <- solve(t(X) %*% X) %*% t(X) %*% Y  # vector len=ncol(X)
             resid <- Y-X %*% t(b)   # T x 1
             SSR1 <- t(resid) %*% resid # 1x1
             # LM stat
             rtn$LM <- Tobs * (SSR0-SSR1)/SSR0
             rtn$pVal <- pchisq(rtn$LM,df=NCOL(r2),lower.tail=FALSE)

             # ROBUST
             # 1 as above
             # 2 regress r2 on r1, get residual vectors
             resid <- matrix(0,Tobs,NCOL(r2))
             X <- r1
             for (i in 1:NCOL(r2)){
               Y <- r2[,i]
               b <- solve(t(X) %*% X) %*% t(X) %*% Y  # vector len=ncol(X)
               resid[,i] <- Y-X %*% t(b)   # T x 1
             }
             # regress 1 on (z2_1)resid, get SSR
             Y <- matrix(1,Tobs,1)
             X <- z2_1*resid
             b <- solve(t(X) %*% X) %*% t(X) %*% Y  # vector len=ncol(X)
             resid <- Y-X %*% t(b)   # T x 1
             SSR <- t(resid) %*% resid # 1x1
             # LM Robust
             rtn$LMrob <- Tobs-SSR
             rtn$pValrob <- pchisq(rtn$LMrob,df=NCOL(r2),lower.tail=FALSE)

             return(rtn)
           }

)



## ========= estimateTVGARCH.1 ==========####
setGeneric(name="estimateTVGARCH.1",
           valueClass = "tvgarch_class",
           signature = c("e","tvgarchObj"),
           def = function(e,tvgarchObj){
             this <- tvgarchObj

             # Use the same starting params each time
             TV <- this$tvObj
             GARCH <- this$garchObj
             this$Estimated <- list()
             estCtrl <- list(calcSE = TRUE, verbose = TRUE)
             calcSE <- TRUE

             optimpars <- c(as.vector(GARCH$pars), as.vector(TV$pars))
             optimpars <- optimpars[!is.na(optimpars)]

             cat("\nStarting Estimation...\n")

             # Now call optim:
             tmp <- NULL
             try(tmp <- optim(optimpars,loglik.tvgarch.univar.1,gr=NULL,e,this, method="BFGS",control=this$optimcontrol,hessian=calcSE))

             # An unhandled error could result in a NULL being returned by optim()
             if (is.null(tmp)) {
               this$Estimated$value <- -Inf
               this$Estimated$error <- TRUE
               warning("estimateTVGARCH() - optim failed unexpectedly and returned NULL. Check the optim controls & starting params")
               return(this)
             }
             if (tmp$convergence!=0) {
               this$Estimated$value <- -Inf
               this$Estimated$error <- TRUE
               this$Estimated$optimoutput <- tmp
               warning("estimateTVGARCH() - failed to converge. Check the optim controls & starting params")
               return(this)
             }

             if(isTRUE(calcSE)) this$Estimated$hessian <- tmp$hessian
             this$Estimated$value <- tmp$value
             this$Estimated$error <- FALSE
             this$Estimated$delta0 <- TV$Estimated$delta0
             this$Estimated$pars <- c(tmp$par)
             this$Estimated$optimoutput <- tmp

             return(this)

           }
)

## ========= summary ==========####
setMethod("summary",signature="tvgarch_class",
          function(object,...){
            this <- object
            cat("\n -- TVGARCH Model Specification --\n")
            cat("\nMultiplicative Model Log-Likelihood Value: ", this$Estimated$finalValue)
            cat("\n\nTVGARCH Model Parameters:")
            summary(this$Estimated$garch)
            summary(this$Estimated$tv)
            cat("\n\n -- End of TVGARCH Model Specification --")
          }
)


## -- generateRefData -- ####
setGeneric(name="generateRefData",
           valueClass = "matrix",
           signature = c("tvObj","garchObj","nr.series","nr.obs"),
           def =  function(tvObj,garchObj,nr.series,nr.obs)
{
           #z    # this will store iid data
           #e    # this will store data with GARCH

    TV <- tvObj
    GARCH <- garchObj
    GARCH$pars["omega",1] <- 1 - GARCH$pars["alpha",1] - GARCH$pars["beta",1]

    nr.rows <- nr.obs + 2000   # discard = 2000
    refData <- matrix(NA,nrow = nr.rows, ncol = nr.series)
    seedstart <- 1984

    for (b in seq(1,nr.series))
    {
      set.seed(seedstart+b)
      e <- z <- rnorm(nr.rows)
      ht_1 <- 1
      e[1] <- z[1]^2
      for (t in 2:nr.rows) {
        ht <- GARCH$pars["omega",1] + GARCH$pars["alpha",1]*(e[t-1])^2 + GARCH$pars["beta",1]*ht_1
          if(GARCH$type == garchtype$gjr) { ht <- ht + GARCH$pars["gamma",1]*(min(e[t-1],0)^2) }
        ht_1 <- ht
        e[t] <- sqrt(ht)*z[t]
      }
      refData[,b] <- as.numeric(e)
    }

    # Discard the first 2000
    startRow <- 2001
    refData <- refData[(startRow:nr.rows),]
    # GARCH data created

    gt <- .calculate_g(TV)
    refData <- refData*sqrt(gt)
    # TV data created

    saveRDS(refData,"refData.RDS")

    #Return:
    refData

  }
)








