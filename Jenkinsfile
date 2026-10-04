pipeline {
    agent { label 'build-agent' }

    options {
        timeout(time: 30, unit: 'MINUTES')
    }

    environment {
        DOCKERHUB_USER = 'keerthana2003bggowd'
        TAG            = "${env.GIT_COMMIT.take(7)}"
        SSH_OPTS       = '-o StrictHostKeyChecking=no'

        HUB            = credentials('dockerhub-creds')      // HUB_USR, HUB_PSW
        KEY            = credentials('jenkins-agent-key')    // path to todo-key.pem
        APP_HOST       = credentials('app-host')             // app server private IP
        MON_HOST       = credentials('monitoring-host')      // monitoring server private IP
        APP_PRIVATE_IP = credentials('app-private-ip')       // same as app-host
    }

    stages {

        stage('Test') {
            steps {
                dir('Backend/todo-summary-assistant') {
                    sh 'mvn -B clean verify'
                }
            }
        }

        stage('Build') {
            steps {
                sh 'docker build -t "$DOCKERHUB_USER/todo-backend:$TAG" Backend/todo-summary-assistant'
                sh 'docker build -t "$DOCKERHUB_USER/todo-frontend:$TAG" Frontend/todo'
            }
        }

        stage('Push') {
            steps {
                sh 'echo "$HUB_PSW" | docker login -u "$HUB_USR" --password-stdin'
                sh 'docker push "$DOCKERHUB_USER/todo-backend:$TAG"'
                sh 'docker push "$DOCKERHUB_USER/todo-frontend:$TAG"'
            }
        }

        stage('Deploy App') {
            
            steps {
                sh 'scp $SSH_OPTS -i $KEY docker-compose.yml ubuntu@$APP_HOST:/opt/todo/'
                sh '''ssh $SSH_OPTS -i $KEY ubuntu@$APP_HOST "/snap/bin/aws ssm get-parameters-by-path --path /todo/prod/ --with-decryption --region ap-south-1 --query 'Parameters[*].[Name,Value]' --output text | sed 's#/todo/prod/##; s#\\t#=#' > /opt/todo/.env"'''
                sh 'ssh $SSH_OPTS -i $KEY ubuntu@$APP_HOST "cd /opt/todo && TAG=$TAG DOCKERHUB_USER=$DOCKERHUB_USER docker compose up -d"'
            }
        }

        stage('Health Check') {
           
            steps {
                retry(10) {
                    sleep 10
                    sh 'curl -f http://$APP_HOST/'
                }
            }
        }

        stage('Deploy Monitoring') {
           
            steps {
                sh 'sed -i "s/APP_IP/$APP_PRIVATE_IP/g" monitoring/prometheus.yml'
                sh 'scp -r $SSH_OPTS -i $KEY monitoring ubuntu@$MON_HOST:/opt/todo/'
                sh '''ssh $SSH_OPTS -i $KEY ubuntu@$MON_HOST "/snap/bin/aws ssm get-parameters-by-path --path /todo/prod/ --with-decryption --region ap-south-1 --query 'Parameters[*].[Name,Value]' --output text | sed 's#/todo/prod/##; s#\\t#=#' > /opt/todo/monitoring/.env"'''
                sh 'ssh $SSH_OPTS -i $KEY ubuntu@$MON_HOST "cd /opt/todo/monitoring && docker compose up -d --force-recreate"'
            }
        }
    }

    post {
        failure { echo 'Pipeline failed - check the failed stage above' }
    }
}